use std::collections::HashSet;
use std::fmt;

const MAXIMUM_DEPTH: usize = 32;

/// Ordered YAML tree node.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum YamlNode {
    Scalar(String),
    Map(Vec<(String, YamlNode)>),
    List(Vec<YamlNode>),
}

/// Parse failure at a specific source line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct YamlParseError {
    pub line: usize,
    pub message: String,
}

impl fmt::Display for YamlParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "line {}: {}", self.line, self.message)
    }
}

impl std::error::Error for YamlParseError {}

impl YamlNode {
    pub fn map_entries(&self) -> Option<&[(String, YamlNode)]> {
        match self {
            YamlNode::Map(entries) => Some(entries),
            _ => None,
        }
    }

    pub fn list_items(&self) -> Option<&[YamlNode]> {
        match self {
            YamlNode::List(items) => Some(items),
            _ => None,
        }
    }

    /// Non-empty scalar only; empty scalars (including null) return `None`.
    pub fn scalar_value(&self) -> Option<&str> {
        match self {
            YamlNode::Scalar(value) if !value.is_empty() => Some(value),
            _ => None,
        }
    }

    pub fn value_for_key(&self, key: &str) -> Option<&YamlNode> {
        self.map_entries()?
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v)
    }
}

/// Backslash parity for an appended closing double quote (shared with the flow-list scanner):
/// odd backslashes escape, even do not.
pub fn is_escaped_double_quote(token_with_quote: &str) -> bool {
    let mut backslashes = 0usize;
    for ch in token_with_quote.chars().rev().skip(1) {
        if ch == '\\' {
            backslashes += 1;
        } else {
            break;
        }
    }
    backslashes % 2 == 1
}

/// Parse YAML text. When `allow_indentless_sequences` is false, list markers at the parent
/// indent (YAML indentless sequence form) are not treated as nested values.
pub fn parse(text: &str, allow_indentless_sequences: bool) -> Result<YamlNode, YamlParseError> {
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut lines: Vec<Line> = Vec::new();
    for (offset, raw) in normalized.split('\n').enumerate() {
        let number = offset + 1;
        let mut indent = 0usize;
        let mut rest = raw;
        while rest.starts_with(' ') {
            indent += 1;
            rest = &rest[1..];
        }
        if rest.starts_with('\t') {
            return Err(YamlParseError {
                line: number,
                message: "tab characters are not allowed for indentation".into(),
            });
        }
        if rest.is_empty() || rest.starts_with('#') {
            continue;
        }
        let content = strip_comment(rest, number)?.trim().to_string();
        if content.is_empty() {
            continue;
        }
        lines.push(Line {
            number,
            indent,
            content,
        });
    }
    let mut parser = Body {
        lines,
        allow_indentless_sequences,
        index: 0,
    };
    if parser.peek().is_none() {
        return Ok(YamlNode::Map(Vec::new()));
    }
    let node = parser.parse(0)?;
    if let Some(trailing) = parser.peek() {
        return Err(YamlParseError {
            line: trailing.number,
            message: "unexpected content".into(),
        });
    }
    Ok(node)
}

#[derive(Clone)]
struct Line {
    number: usize,
    indent: usize,
    content: String,
}
struct Body {
    lines: Vec<Line>,
    allow_indentless_sequences: bool,
    index: usize,
}

impl Body {
    fn peek(&self) -> Option<&Line> {
        self.lines.get(self.index)
    }

    fn parse(&mut self, depth: usize) -> Result<YamlNode, YamlParseError> {
        if depth >= MAXIMUM_DEPTH {
            return Err(YamlParseError {
                line: self.peek().map(|l| l.number).unwrap_or(0),
                message: "profile nesting is too deep".into(),
            });
        }
        let line = self.peek().ok_or(YamlParseError {
            line: 0,
            message: "expected a value".into(),
        })?;
        if line.content == "-" || line.content.starts_with("- ") {
            let indent = line.indent;
            return self.parse_list(indent, depth);
        }
        let indent = line.indent;
        self.parse_map(indent, depth)
    }

    fn parse_list(&mut self, indent: usize, depth: usize) -> Result<YamlNode, YamlParseError> {
        let mut items: Vec<YamlNode> = Vec::new();
        while let Some(line) = self.peek().cloned() {
            if line.indent != indent {
                break;
            }
            if line.content != "-" && !line.content.starts_with("- ") {
                break;
            }
            let line_number = line.number;
            self.index += 1;
            let rest = line.content[1..].trim();
            if rest.is_empty() {
                if let Some(next) = self.peek() {
                    if next.indent > indent {
                        items.push(self.parse(depth + 1)?);
                    } else {
                        items.push(YamlNode::Scalar(String::new()));
                    }
                } else {
                    items.push(YamlNode::Scalar(String::new()));
                }
            } else if is_mapping_entry(rest) {
                let inserted = Line {
                    number: line_number,
                    indent: indent + 2,
                    content: rest.to_string(),
                };
                self.lines.insert(self.index, inserted);
                items.push(self.parse_map(indent + 2, depth + 1)?);
            } else {
                items.push(self.parse_scalar(rest, line_number)?);
            }
        }
        Ok(YamlNode::List(items))
    }

    fn parse_map(&mut self, indent: usize, depth: usize) -> Result<YamlNode, YamlParseError> {
        let mut entries: Vec<(String, YamlNode)> = Vec::new();
        let mut seen: HashSet<String> = HashSet::new();
        while let Some(line) = self.peek().cloned() {
            if line.indent != indent {
                break;
            }
            if line.content == "-" || line.content.starts_with("- ") {
                let prefix: String = line.content.chars().take(8).collect();
                return Err(YamlParseError {
                    line: line.number,
                    message: format!(
                        "unexpected list marker \"{prefix}\"; list items must be indented beneath their parent key"
                    ),
                });
            }
            let line_number = line.number;
            let (key, value_text) = split_key_value(&line.content).ok_or(YamlParseError {
                line: line_number,
                message: "expected \"key: value\"".into(),
            })?;
            if !seen.insert(key.clone()) {
                return Err(YamlParseError {
                    line: line_number,
                    message: format!("duplicate key \"{key}\""),
                });
            }
            self.index += 1;
            if value_text.is_empty() {
                let next_is_indentless_list = self.allow_indentless_sequences
                    && self
                        .peek()
                        .map(|next| {
                            next.indent == indent
                                && (next.content == "-" || next.content.starts_with("- "))
                        })
                        .unwrap_or(false);
                if let Some(next) = self.peek() {
                    if next.indent > indent || next_is_indentless_list {
                        entries.push((key, self.parse(depth + 1)?));
                    } else {
                        entries.push((key, YamlNode::Scalar(String::new())));
                    }
                } else {
                    entries.push((key, YamlNode::Scalar(String::new())));
                }
            } else {
                entries.push((key, self.parse_scalar(&value_text, line_number)?));
            }
        }
        Ok(YamlNode::Map(entries))
    }

    fn parse_scalar(&self, content: &str, line: usize) -> Result<YamlNode, YamlParseError> {
        if content.starts_with('[') {
            return Ok(YamlNode::List(parse_flow_list(content, line)?));
        }
        if content.starts_with('{') {
            return Err(YamlParseError {
                line,
                message: "flow mappings are not supported; use indented keys".into(),
            });
        }
        if content.starts_with('"') || content.starts_with('\'') {
            return Ok(YamlNode::Scalar(parse_quoted(content, line)?));
        }
        if content == "null" || content == "~" || content == "Null" || content == "NULL" {
            return Ok(YamlNode::Scalar(String::new()));
        }
        Ok(YamlNode::Scalar(content.to_string()))
    }
}

fn is_mapping_entry(content: &str) -> bool {
    let Some(colon_idx) = content.find(':') else {
        return false;
    };
    let next_idx = colon_idx + 1;
    next_idx >= content.len()
        || content.as_bytes()[next_idx] == b' '
        || content.as_bytes()[next_idx] == b'\t'
}

fn split_key_value(content: &str) -> Option<(String, String)> {
    let colon_idx = content.find(':')?;
    let next_idx = colon_idx + 1;
    if next_idx < content.len() {
        let next = content.as_bytes()[next_idx];
        if next != b' ' && next != b'\t' {
            return None;
        }
    }
    let key = content[..colon_idx].trim();
    if key.is_empty() || key.contains('"') || key.contains('\'') {
        return None;
    }
    let value = if next_idx >= content.len() {
        String::new()
    } else {
        content[next_idx..].trim().to_string()
    };
    Some((key.to_string(), value))
}

fn parse_flow_list(content: &str, line: usize) -> Result<Vec<YamlNode>, YamlParseError> {
    if !content.ends_with(']') {
        return Err(YamlParseError {
            line,
            message: "flow list is missing its closing \"]\"".into(),
        });
    }
    let inner = &content[1..content.len() - 1];
    let inner_is_blank = inner.trim().is_empty();
    let mut items: Vec<YamlNode> = Vec::new();
    let mut token = String::new();
    let mut quote: Option<char> = None;
    let finish_token = |items: &mut Vec<YamlNode>,
                        token: &mut String,
                        inner_is_blank: bool,
                        line: usize|
     -> Result<(), YamlParseError> {
        let trimmed = token.trim().to_string();
        token.clear();
        if trimmed.is_empty() {
            if inner_is_blank {
                return Ok(());
            }
            return Err(YamlParseError {
                line,
                message: "empty element in flow list".into(),
            });
        }
        if trimmed.starts_with('[') || trimmed.starts_with('{') {
            return Err(YamlParseError {
                line,
                message: "nested flow collections are not supported".into(),
            });
        }
        if trimmed.starts_with('"') || trimmed.starts_with('\'') {
            items.push(YamlNode::Scalar(parse_quoted(&trimmed, line)?));
        } else {
            items.push(YamlNode::Scalar(trimmed));
        }
        Ok(())
    };

    for character in inner.chars() {
        if let Some(active) = quote {
            token.push(character);
            if character == active && (active == '\'' || !is_escaped_double_quote(&token)) {
                quote = None;
            }
            if active == '\'' && token.ends_with("''") {
                quote = Some('\'');
            }
        } else if character == '"' || character == '\'' {
            quote = Some(character);
            token.push(character);
        } else if character == ',' {
            finish_token(&mut items, &mut token, inner_is_blank, line)?;
        } else {
            token.push(character);
        }
    }
    if quote.is_some() {
        return Err(YamlParseError {
            line,
            message: "unterminated quoted value".into(),
        });
    }
    finish_token(&mut items, &mut token, inner_is_blank, line)?;
    Ok(items)
}

fn parse_quoted(content: &str, line: usize) -> Result<String, YamlParseError> {
    if content.starts_with('\'') {
        if content.len() < 2 || !content.ends_with('\'') {
            return Err(YamlParseError {
                line,
                message: "unterminated single-quoted value".into(),
            });
        }
        let inner = &content[1..content.len() - 1];
        return Ok(inner.replace("''", "'"));
    }
    if content.len() < 2 || !content.ends_with('"') {
        return Err(YamlParseError {
            line,
            message: "unterminated double-quoted value".into(),
        });
    }
    let inner: Vec<char> = content[1..content.len() - 1].chars().collect();
    let mut result = String::new();
    let mut i = 0usize;
    while i < inner.len() {
        let character = inner[i];
        if character != '\\' {
            result.push(character);
            i += 1;
            continue;
        }
        i += 1;
        let escape = inner.get(i).copied().ok_or(YamlParseError {
            line,
            message: "unterminated escape sequence".into(),
        })?;
        i += 1;
        match escape {
            '"' => result.push('"'),
            '\\' => result.push('\\'),
            'n' => result.push('\n'),
            't' => result.push('\t'),
            'r' => result.push('\r'),
            'u' => {
                let mut hex = String::new();
                for _ in 0..4 {
                    let digit = inner.get(i).copied().ok_or(YamlParseError {
                        line,
                        message: "truncated \\u escape".into(),
                    })?;
                    hex.push(digit);
                    i += 1;
                }
                let scalar = u32::from_str_radix(&hex, 16).map_err(|_| YamlParseError {
                    line,
                    message: "invalid \\u escape".into(),
                })?;
                let ch = char::from_u32(scalar).ok_or(YamlParseError {
                    line,
                    message: "invalid \\u escape".into(),
                })?;
                result.push(ch);
            }
            _ => {
                return Err(YamlParseError {
                    line,
                    message: format!("unsupported escape \"\\{escape}\""),
                });
            }
        }
    }
    Ok(result)
}

fn strip_comment(body: &str, _line: usize) -> Result<String, YamlParseError> {
    let mut quote: Option<char> = None;
    let mut previous: char = ' ';
    let mut result = String::new();
    for character in body.chars() {
        if let Some(active) = quote {
            result.push(character);
            if active == '\'' {
                if character == '\'' {
                    quote = None;
                }
            } else if character == '"' && !is_escaped_double_quote(&result) {
                quote = None;
            }
        } else if character == '"' || character == '\'' {
            quote = Some(character);
            result.push(character);
        } else if character == '#' && (previous == ' ' || previous == '\t' || result.is_empty()) {
            break;
        } else {
            result.push(character);
        }
        previous = character;
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    const GRAMMAR_EXAMPLE: &str = r#"schema_version: 1
grammars:
  - id: standard-scientific
    name: Standard Filename Pattern
    template: "{instrument}.{mode}_{sample}"
    fields:
      - name: instrument
        role: instrument
        type: string
        optional: false
      - name: mode
        role: mode
        type: string
        optional: false
      - name: sample
        role: sample
        type: string
        optional: false
"#;

    #[test]
    fn spec_grammar_example_parses() {
        let node = parse(GRAMMAR_EXAMPLE, true).expect("grammar example should parse");
        let grammars = node
            .value_for_key("grammars")
            .and_then(|n| n.list_items())
            .expect("grammars list");
        assert_eq!(grammars.len(), 1);
        assert_eq!(
            grammars[0]
                .value_for_key("template")
                .and_then(|n| n.scalar_value()),
            Some("{instrument}.{mode}_{sample}")
        );
        assert_eq!(
            grammars[0]
                .value_for_key("fields")
                .and_then(|n| n.list_items())
                .map(|l| l.len()),
            Some(3)
        );
    }

    #[test]
    fn indentless_sequences_disabled_rejects_parent_indent_list() {
        let yaml = "parent:\n  child: value\n- sibling\n";
        let err = parse(yaml, false).expect_err("parent-indent list should fail");
        assert!(err.message.contains("unexpected list marker"));
        assert_eq!(
            err.to_string(),
            format!("line {}: {}", err.line, err.message)
        );
    }

    #[test]
    fn empty_input_yields_empty_map() {
        let node = parse("", true).unwrap();
        assert_eq!(node, YamlNode::Map(Vec::new()));
    }

    #[test]
    fn duplicate_key_error() {
        let err = parse("a: 1\na: 2\n", true).unwrap_err();
        assert_eq!(err.message, "duplicate key \"a\"");
    }

    #[test]
    fn flow_list_rejects_empty_element() {
        assert!(parse("key: [\"a\", , \"b\"]\n", true).is_err());
    }

    #[test]
    fn flow_list_rejects_trailing_comma() {
        assert!(parse("key: [\".csv\", ]\n", true).is_err());
    }

    #[test]
    fn flow_list_even_backslash_before_quote() {
        let node = parse("key: [\"a\\\\\"]\n", true).unwrap();
        let items = node
            .value_for_key("key")
            .and_then(|n| n.list_items())
            .unwrap();
        assert_eq!(items.len(), 1);
    }

    #[test]
    fn tab_indentation_rejected() {
        let err = parse("\tkey: value\n", true).unwrap_err();
        assert_eq!(
            err.message,
            "tab characters are not allowed for indentation"
        );
    }

    #[test]
    fn scalar_value_empty_returns_none() {
        let node = YamlNode::Scalar(String::new());
        assert!(node.scalar_value().is_none());
        let null_node = parse("key: null\n", true).unwrap();
        assert!(null_node
            .value_for_key("key")
            .unwrap()
            .scalar_value()
            .is_none());
    }
}
