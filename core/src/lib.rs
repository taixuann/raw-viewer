/// Placeholder identity for the shared core.
/// Later steps replace this with config, readers, and measurements.
pub fn core_placeholder() -> &'static str {
    "raw-viewer-core"
}

#[cfg(test)]
mod tests {
    use super::core_placeholder;

    #[test]
    fn placeholder_names_the_crate() {
        assert_eq!(core_placeholder(), "raw-viewer-core");
    }
}
