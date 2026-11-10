use clap::{Parser, Subcommand};
use envelope::{CliResult, ErrorDetail, ErrorEnvelope, SuccessEnvelope, EXIT_USAGE};
use std::path::PathBuf;
use std::process;

mod commands;
mod envelope;

#[derive(Parser)]
#[command(
    name = "raw-viewer",
    about = "RawView scientific raw instrument data CLI over the Rust core",
    version
)]
struct Cli {
    #[arg(long, global = true, help = "Output structured JSON on stdout")]
    json: bool,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    #[command(about = "System diagnostic: paths, grammar source, profiles, skills status")]
    Doctor,

    #[command(about = "Project commands")]
    Projects {
        #[command(subcommand)]
        cmd: ProjectsCommands,
    },

    #[command(about = "Configuration commands")]
    Config {
        #[command(subcommand)]
        cmd: ConfigCommands,
    },

    #[command(about = "Filename grammar commands")]
    Grammar {
        #[command(subcommand)]
        cmd: GrammarCommands,
    },

    #[command(about = "Instrument profile commands")]
    Profiles {
        #[command(subcommand)]
        cmd: ProfilesCommands,
    },

    #[command(about = "Manage optional lab packages")]
    Packages {
        #[command(subcommand)]
        cmd: PackagesCommands,
    },

    #[command(about = "File inspection, matching, and data export")]
    Files {
        #[command(subcommand)]
        cmd: FilesCommands,
    },

    #[command(about = "Agent skills management")]
    Skills {
        #[command(subcommand)]
        cmd: SkillsCommands,
    },

    #[command(about = "Check for and install updates from GitHub releases")]
    Update {
        #[arg(long, help = "Only check for available updates without downloading")]
        check: bool,
    },
}

#[derive(Subcommand)]
enum ProjectsCommands {
    #[command(about = "Resolve project metadata and configuration at PATH")]
    Resolve {
        #[arg(long, help = "Project root directory")]
        path: PathBuf,
    },
}

#[derive(Subcommand)]
enum ConfigCommands {
    #[command(about = "Get configuration")]
    Get {
        #[arg(long, help = "Read global config")]
        global: bool,

        #[arg(long, help = "Project path")]
        project: Option<PathBuf>,
    },
    #[command(about = "Set configuration key")]
    Set {
        #[arg(long, help = "Update global config")]
        global: bool,

        #[arg(long, help = "Project path")]
        project: Option<PathBuf>,

        #[arg(long, help = "Configuration key")]
        key: String,

        #[arg(long, help = "Configuration value")]
        value: String,

        #[arg(long, help = "Dry-run without modifying filesystem")]
        dry_run: bool,
    },
}

#[derive(Subcommand)]
enum GrammarCommands {
    #[command(about = "Show active grammar")]
    Show {
        #[arg(long, help = "Global grammar")]
        global: bool,

        #[arg(long, help = "Project path")]
        project: Option<PathBuf>,
    },
    #[command(about = "Set active grammar from file")]
    Set {
        #[arg(long, help = "Global grammar")]
        global: bool,

        #[arg(long, help = "Project path")]
        project: Option<PathBuf>,

        #[arg(long, help = "Grammar YAML file")]
        file: PathBuf,

        #[arg(long, help = "Dry-run without modifying filesystem")]
        dry_run: bool,
    },
    #[command(about = "Test filename(s) against active grammar")]
    Test {
        #[arg(long, help = "Global grammar")]
        global: bool,

        #[arg(long, help = "Project path")]
        project: Option<PathBuf>,

        #[arg(
            long = "filename",
            required = true,
            num_args = 1..,
            help = "Filename(s) to test against grammar"
        )]
        filenames: Vec<String>,
    },
}

#[derive(Subcommand)]
enum ProfilesCommands {
    #[command(about = "List available profiles")]
    List {
        #[arg(long, help = "Global profiles")]
        global: bool,

        #[arg(long, help = "Project path")]
        project: Option<PathBuf>,
    },
    #[command(about = "Enable profile in project")]
    Enable {
        #[arg(long, help = "Project path")]
        project: PathBuf,

        #[arg(long, help = "Profile id (namespace/id)")]
        id: String,

        #[arg(long, help = "Dry-run without modifying filesystem")]
        dry_run: bool,
    },
    #[command(about = "Disable profile in project")]
    Disable {
        #[arg(long, help = "Project path")]
        project: PathBuf,

        #[arg(long, help = "Profile id (namespace/id)")]
        id: String,

        #[arg(long, help = "Dry-run without modifying filesystem")]
        dry_run: bool,
    },
    #[command(about = "Import profile into project")]
    Import {
        #[arg(long, help = "Project path")]
        project: PathBuf,

        #[arg(long, help = "Profile YAML file")]
        file: PathBuf,

        #[arg(long, help = "Dry-run without modifying filesystem")]
        dry_run: bool,

        #[arg(long, help = "Replace existing profile with same ID")]
        replace: bool,
    },
    #[command(about = "Export profile definition")]
    Export {
        #[arg(long, help = "Global profiles")]
        global: bool,

        #[arg(long, help = "Project path")]
        project: Option<PathBuf>,

        #[arg(long, help = "Profile id (namespace/id)")]
        id: String,

        #[arg(
            long,
            help = "Output file path or '-' for stdout (default: ./<safe-id>.yaml in cwd)"
        )]
        out: Option<String>,
    },
    #[command(about = "Create a new instrument profile template (Schema v4)")]
    Create {
        #[arg(help = "Profile ID in namespace/name format (e.g. usth/fluorospec)")]
        id: String,

        #[arg(long, help = "Instrument name")]
        name: Option<String>,

        #[arg(long, help = "Output file path or directory (defaults to cwd)")]
        out: Option<String>,
    },
}

#[derive(Subcommand)]
enum PackagesCommands {
    #[command(about = "List installed and available lab packages")]
    List,

    #[command(about = "Install lab package (use --usth or --from <path>)")]
    Install {
        #[arg(long, help = "Install bundled USTH Clean Energy Lab Profiles package")]
        usth: bool,

        #[arg(long, help = "Install custom package from directory or manifest")]
        from: Option<PathBuf>,

        #[arg(long, help = "Replace package if already installed")]
        replace: bool,
    },

    #[command(about = "Remove an installed package and its global profiles")]
    Remove {
        #[arg(help = "Package ID to remove (e.g. usth-lab)")]
        id: String,
    },
}

#[derive(Subcommand)]
enum FilesCommands {
    #[command(about = "Inspect file using grammar tokens and matched instrument profile")]
    Inspect {
        #[arg(long, help = "Project path")]
        project: PathBuf,

        #[arg(long, help = "Relative path to file in project")]
        file: String,
    },
    #[command(about = "Match file and display trace")]
    Match {
        #[arg(long, help = "Project path")]
        project: PathBuf,

        #[arg(long, help = "Relative path to file in project")]
        file: String,
    },
    #[command(about = "Export measurement data to CSV or JSON")]
    Export {
        #[arg(long, help = "Project path")]
        project: PathBuf,

        #[arg(long, help = "Relative path to file in project")]
        file: String,

        #[arg(long, default_value = "csv", help = "Export format: csv or json")]
        format: String,

        #[arg(long, help = "Output file path or '-' for stdout")]
        out: String,

        #[arg(long, help = "Dry-run without writing file")]
        dry_run: bool,
    },
}

#[derive(Subcommand)]
enum SkillsCommands {
    #[command(about = "Install shipped skills to agent skill paths")]
    Install {
        #[arg(long, help = "Dry-run without modifying filesystem")]
        dry_run: bool,
    },
    #[command(about = "Repair or retarget shipped skill links")]
    Repair {
        #[arg(long, help = "Dry-run without modifying filesystem")]
        dry_run: bool,
    },
}

fn main() {
    let cli = match Cli::try_parse() {
        Ok(c) => c,
        Err(e) => {
            if e.kind() == clap::error::ErrorKind::DisplayHelp
                || e.kind() == clap::error::ErrorKind::DisplayVersion
            {
                e.exit();
            }
            let is_json = std::env::args().any(|a| a == "--json");
            if is_json {
                let err_env = ErrorEnvelope {
                    ok: false,
                    command: "usage".to_string(),
                    error: ErrorDetail {
                        code: "bad_usage".to_string(),
                        message: e.to_string(),
                        details: serde_json::json!({}),
                    },
                };
                println!("{}", serde_json::to_string_pretty(&err_env).unwrap());
            } else {
                eprintln!("{e}");
            }
            process::exit(EXIT_USAGE);
        }
    };

    let (command_name, result): (&str, CliResult) = match &cli.command {
        Commands::Doctor => ("doctor", commands::doctor::run()),
        Commands::Projects { cmd } => match cmd {
            ProjectsCommands::Resolve { path } => {
                ("projects.resolve", commands::projects::resolve(path))
            }
        },
        Commands::Config { cmd } => match cmd {
            ConfigCommands::Get { global, project } => (
                "config.get",
                commands::config::get(*global, project.as_deref()),
            ),
            ConfigCommands::Set {
                global,
                project,
                key,
                value,
                dry_run,
            } => (
                "config.set",
                commands::config::set(*global, project.as_deref(), key, value, *dry_run),
            ),
        },
        Commands::Grammar { cmd } => match cmd {
            GrammarCommands::Show { global, project } => (
                "grammar.show",
                commands::grammar::show(*global, project.as_deref()),
            ),
            GrammarCommands::Set {
                global,
                project,
                file,
                dry_run,
            } => (
                "grammar.set",
                commands::grammar::set(*global, project.as_deref(), file, *dry_run),
            ),
            GrammarCommands::Test {
                global,
                project,
                filenames,
            } => (
                "grammar.test",
                commands::grammar::test(*global, project.as_deref(), filenames),
            ),
        },
        Commands::Profiles { cmd } => match cmd {
            ProfilesCommands::List { global, project } => (
                "profiles.list",
                commands::profiles::list(*global, project.as_deref()),
            ),
            ProfilesCommands::Enable {
                project,
                id,
                dry_run,
            } => (
                "profiles.enable",
                commands::profiles::enable(project, id, *dry_run),
            ),
            ProfilesCommands::Disable {
                project,
                id,
                dry_run,
            } => (
                "profiles.disable",
                commands::profiles::disable(project, id, *dry_run),
            ),
            ProfilesCommands::Import {
                project,
                file,
                dry_run,
                replace,
            } => (
                "profiles.import",
                commands::profiles::import_profile(project, file, *dry_run, *replace),
            ),
            ProfilesCommands::Export {
                global,
                project,
                id,
                out,
            } => (
                "profiles.export",
                commands::profiles::export_profile(*global, project.as_deref(), id, out.as_deref()),
            ),
            ProfilesCommands::Create { id, name, out } => (
                "profiles.create",
                commands::profiles::create_profile(id, name.as_deref(), out.as_deref()),
            ),
        },
        Commands::Packages { cmd } => match cmd {
            PackagesCommands::List => ("packages.list", commands::packages::list()),
            PackagesCommands::Install {
                usth,
                from,
                replace,
            } => (
                "packages.install",
                commands::packages::install(*usth, from.as_deref(), *replace),
            ),
            PackagesCommands::Remove { id } => ("packages.remove", commands::packages::remove(id)),
        },
        Commands::Files { cmd } => match cmd {
            FilesCommands::Inspect { project, file } => {
                ("files.inspect", commands::files::inspect(project, file))
            }
            FilesCommands::Match { project, file } => {
                ("files.match", commands::files::match_file(project, file))
            }
            FilesCommands::Export {
                project,
                file,
                format,
                out,
                dry_run,
            } => (
                "files.export",
                commands::files::export_file(project, file, format, out, *dry_run),
            ),
        },
        Commands::Skills { cmd } => match cmd {
            SkillsCommands::Install { dry_run } => (
                "skills.install",
                commands::skills::manage_skills("install", *dry_run),
            ),
            SkillsCommands::Repair { dry_run } => (
                "skills.repair",
                commands::skills::manage_skills("repair", *dry_run),
            ),
        },
        Commands::Update { check } => ("update", commands::update::run(*check, cli.json)),
    };

    match result.output {
        Ok(data) => {
            if cli.json {
                let envelope = SuccessEnvelope {
                    ok: true,
                    command: command_name.to_string(),
                    data,
                };
                println!("{}", serde_json::to_string(&envelope).unwrap());
            } else {
                println!("{}", serde_json::to_string_pretty(&data).unwrap());
            }
            process::exit(result.exit_code);
        }
        Err((code, message, details)) => {
            if cli.json {
                let envelope = ErrorEnvelope {
                    ok: false,
                    command: command_name.to_string(),
                    error: ErrorDetail {
                        code,
                        message,
                        details,
                    },
                };
                println!("{}", serde_json::to_string(&envelope).unwrap());
            } else {
                eprintln!("Error ({}): {}", code, message);
            }
            process::exit(result.exit_code);
        }
    }
}
