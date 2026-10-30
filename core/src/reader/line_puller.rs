use crate::reader::ReaderError;
use encoding_rs::WINDOWS_1252;
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::Read;

pub const CHUNK_BYTES: usize = 65536;
pub const MAXIMUM_SOURCE_LINE_BYTES: usize = 1 << 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextEncoding {
    Utf8,
    Windows1252,
    Iso8859_1,
    Ascii,
}

pub fn encoding_from_name(name: &str) -> Option<TextEncoding> {
    match name.to_lowercase().as_str() {
        "utf-8" | "utf8" => Some(TextEncoding::Utf8),
        "windows-1252" | "cp1252" => Some(TextEncoding::Windows1252),
        "iso-8859-1" | "latin-1" | "latin1" => Some(TextEncoding::Iso8859_1),
        "ascii" | "us-ascii" => Some(TextEncoding::Ascii),
        _ => None,
    }
}

pub struct LinePuller {
    file: File,
    hasher: Sha256,
    encoding: TextEncoding,
    relative_path: String,
    pending_bytes: Vec<u8>,
    text_buffer: String,
    ready_lines: Vec<String>,
    ready_index: usize,
    eof: bool,
    final_flushed: bool,
    lines_emitted: usize,
    pending_cr: bool,
}

impl LinePuller {
    pub fn new(
        mut file: File,
        encoding: TextEncoding,
        relative_path: String,
        pending_bytes: Vec<u8>,
        prefix_hashed: &[u8],
    ) -> Self {
        let mut hasher = Sha256::new();
        hasher.update(prefix_hashed);
        Self {
            file,
            encoding,
            relative_path,
            pending_bytes,
            text_buffer: String::new(),
            ready_lines: Vec::new(),
            ready_index: 0,
            eof: false,
            final_flushed: false,
            lines_emitted: 0,
            pending_cr: false,
        }
    }

    pub fn stage_text(&mut self, text: &str, final_chunk: bool) -> Result<(), ReaderError> {
        let normalized = self.normalize_chunk(text);
        self.text_buffer.push_str(&normalized);
        self.drain_lines(final_chunk)
    }

    pub fn next_line(&mut self) -> Result<Option<String>, ReaderError> {
        loop {
            if self.ready_index < self.ready_lines.len() {
                self.lines_emitted += 1;
                let mut line = self.ready_lines[self.ready_index].clone();
                self.ready_index += 1;
                if self.ready_index == self.ready_lines.len() {
                    self.ready_lines.clear();
                    self.ready_index = 0;
                } else if self.ready_index > 1024 && self.ready_index > self.ready_lines.len() / 2 {
                    let rest = self.ready_lines.split_off(self.ready_index);
                    self.ready_lines = rest;
                    self.ready_index = 0;
                }
                if self.lines_emitted == 1 && line.starts_with('\u{feff}') {
                    line = line.trim_start_matches('\u{feff}').to_string();
                }
                if line.len() > MAXIMUM_SOURCE_LINE_BYTES {
                    return Err(ReaderError::InvalidSource(format!(
                        "{}: source line {} exceeds the 1 MiB line limit.",
                        self.relative_path, self.lines_emitted
                    )));
                }
                return Ok(Some(line));
            }
            if self.eof {
                if self.final_flushed {
                    return Ok(None);
                }
                self.final_flushed = true;
                if self.pending_cr {
                    self.pending_cr = false;
                    self.text_buffer.push('\n');
                }
                if !self.pending_bytes.is_empty() {
                    let tail = decode_bytes(&self.pending_bytes, self.encoding).ok_or_else(|| {
                        ReaderError::InvalidSource(format!(
                            "{}: could not decode the file using the selected encoding.",
                            self.relative_path
                        ))
                    })?;
                    self.pending_bytes.clear();
                    self.stage_text(&tail, true)?;
                } else {
                    self.drain_lines(true)?;
                }
                continue;
            }
            self.fill()?;
        }
    }

    pub fn digest_hex(&self) -> String {
        let digest = self.hasher.clone().finalize();
        digest.iter().map(|b| format!("{b:02x}")).collect()
    }

    fn fill(&mut self) -> Result<(), ReaderError> {
        let mut chunk = vec![0u8; CHUNK_BYTES];
        let read = self.file.read(&mut chunk).map_err(|err| {
            ReaderError::InvalidSource(format!(
                "{}: could not read the source file: {err}",
                self.relative_path
            ))
        })?;
        if read == 0 {
            self.eof = true;
            return Ok(());
        }
        chunk.truncate(read);
        self.hasher.update(&chunk);
        let text = decode_chunk_with_pending(&mut self.pending_bytes, &chunk, self.encoding)?;
        self.stage_text(&text, false)
    }

    fn drain_lines(&mut self, final_chunk: bool) -> Result<(), ReaderError> {
        let mut parts: Vec<&str> = self.text_buffer.split('\n').collect();
        if final_chunk {
            self.text_buffer.clear();
        } else {
            self.text_buffer = parts.pop().unwrap_or("").to_string();
        }
        for part in &parts {
            if part.len() > MAXIMUM_SOURCE_LINE_BYTES {
                return Err(ReaderError::InvalidSource(format!(
                    "{}: source line exceeds the 1 MiB line limit.",
                    self.relative_path
                )));
            }
        }
        if !final_chunk && self.text_buffer.len() > MAXIMUM_SOURCE_LINE_BYTES {
            return Err(ReaderError::InvalidSource(format!(
                "{}: source line exceeds the 1 MiB line limit.",
                self.relative_path
            )));
        }
        self.ready_lines
            .extend(parts.into_iter().map(str::to_string));
        Ok(())
    }

    fn normalize_chunk(&mut self, text: &str) -> String {
        let mut combined = String::new();
        if self.pending_cr {
            combined.push('\r');
        }
        combined.push_str(text);
        self.pending_cr = combined.ends_with('\r');
        if self.pending_cr {
            combined.pop();
        }
        combined.replace("\r\n", "\n").replace('\r', "\n")
    }
}

pub fn decode_with_format(
    prefix: &[u8],
    encoding_names: &[String],
) -> Option<(TextEncoding, String, Vec<u8>)> {
    for name in encoding_names {
        let encoding = encoding_from_name(name)?;
        if encoding == TextEncoding::Utf8 {
            let mut candidate = prefix.to_vec();
            for _ in 0..4 {
                if let Some(text) = std::str::from_utf8(&candidate).ok().map(str::to_string) {
                    let pending = prefix[candidate.len()..].to_vec();
                    return Some((TextEncoding::Utf8, text, pending));
                }
                if candidate.is_empty() {
                    break;
                }
                candidate.pop();
            }
        } else if let Some(text) = decode_bytes(prefix, encoding) {
            return Some((encoding, text, Vec::new()));
        }
    }
    None
}

fn decode_chunk_with_pending(
    pending: &mut Vec<u8>,
    chunk: &[u8],
    encoding: TextEncoding,
) -> Result<String, ReaderError> {
    pending.extend_from_slice(chunk);
    match encoding {
        TextEncoding::Utf8 => {
            let mut candidate_len = pending.len();
            while candidate_len > 0 {
                if let Ok(text) = std::str::from_utf8(&pending[..candidate_len]) {
                    let rest = pending.split_off(candidate_len);
                    *pending = rest;
                    return Ok(text.to_string());
                }
                candidate_len -= 1;
            }
            Ok(String::new())
        }
        _ => {
            let all = pending.clone();
            pending.clear();
            decode_bytes(&all, encoding).ok_or_else(|| {
                ReaderError::InvalidSource("could not decode source bytes".into())
            })
        }
    }
}

fn decode_bytes(bytes: &[u8], encoding: TextEncoding) -> Option<String> {
    match encoding {
        TextEncoding::Utf8 => std::str::from_utf8(bytes).ok().map(str::to_string),
        TextEncoding::Ascii => std::str::from_utf8(bytes).ok().map(str::to_string),
        TextEncoding::Windows1252 => {
            let (cow, _, _) = WINDOWS_1252.decode(bytes);
            Some(cow.into_owned())
        }
        TextEncoding::Iso8859_1 => encoding_rs::Encoding::for_label(b"iso-8859-1").and_then(|enc| {
            let (cow, _, _) = enc.decode(bytes);
            Some(cow.into_owned())
        }),
    }
}

pub fn file_size(path: &std::path::Path) -> Result<u64, ReaderError> {
    std::fs::metadata(path)
        .map(|m| m.len())
        .map_err(|err| {
            ReaderError::InvalidSource(format!(
                "{}: could not read the source file: {err}",
                path.display()
            ))
        })
}
