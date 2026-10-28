use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Project {
    pub root: PathBuf,
    pub languages: Vec<String>,
    pub config_files: HashMap<String, PathBuf>,
    pub git_root: Option<PathBuf>,
}

impl Project {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            languages: Vec::new(),
            config_files: HashMap::new(),
            git_root: None,
        }
    }

    pub fn detect_languages(&mut self) {
        use walkdir::WalkDir;
        
        let extensions = [
            ("rs", "rust"),
            ("dart", "dart"),
            ("ts", "typescript"),
            ("tsx", "typescript"),
            ("js", "typescript"),
            ("jsx", "typescript"),
            ("py", "python"),
            ("go", "go"),
        ];

        let mut found = std::collections::HashSet::new();
        
        for entry in WalkDir::new(&self.root).into_iter().filter_map(|e| e.ok()) {
            if let Some(ext) = entry.path().extension().and_then(|e| e.to_str()) {
                for (e, lang) in &extensions {
                    if ext == *e {
                        found.insert(lang.to_string());
                    }
                }
            }
        }
        
        self.languages = found.into_iter().collect();
        self.languages.sort();
    }

    pub fn find_config(&self, name: &str) -> Option<&PathBuf> {
        self.config_files.get(name)
    }
}