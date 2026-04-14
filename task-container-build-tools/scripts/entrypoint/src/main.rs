use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread;

use chrono::Utc;
use regex::Regex;

fn log_info(msg: &str) {
    let now = Utc::now();
    println!("{} {}", now.format("%Y-%m-%dT%H:%M:%SZ"), msg);
}

fn env_or_panic(name: &str, is_required: bool) -> Option<String> {
    match env::var(name) {
        Ok(v) => Some(v),
        Err(_) => {
            if is_required {
                log_info(&format!("'{}' env is required", name));
                std::process::exit(1);
            }
            None
        }
    }
}

fn user_exists() -> bool {
    let uid = unsafe { libc::getuid() };
    let passwd_path = "/etc/passwd";
    if let Ok(file) = File::open(passwd_path) {
        let reader = BufReader::new(file);
        for line in reader.lines() {
            if let Ok(l) = line {
                let parts: Vec<&str> = l.split(':').collect();
                if parts.len() > 2 && parts[2] == uid.to_string() {
                    return true;
                }
            }
        }
    }
    false
}

fn download_file(url: &str, filename: &str) -> bool {
    log_info(&format!("Downloading {}", url));
    let mut response = match reqwest::blocking::get(url) {
        Ok(res) => {
            if !res.status().is_success() {
                log_info("Download failed with non-success status code");
                return false;
            }
            res
        }
        Err(e) => {
            log_info(&format!("Download failed: {}", e));
            return false;
        }
    };

    let mut file = match File::create(filename) {
        Ok(f) => f,
        Err(e) => {
            log_info(&format!("Failed to create file {}: {}", filename, e));
            return false;
        }
    };

    if let Err(e) = io::copy(&mut response, &mut file) {
        log_info(&format!("Failed to write to file: {}", e));
        let _ = fs::remove_file(filename);
        return false;
    }

    log_info(&format!("File saved to {}", filename));
    true
}

fn check_set_exec_script(source: &str, dest: &str) -> bool {
    let src_path = Path::new(source);
    if !src_path.exists() || src_path.is_dir() {
        return false;
    }

    if let Ok(metadata) = fs::metadata(src_path) {
        if metadata.len() == 0 {
            return false;
        }
    } else {
        return false;
    }

    log_info("Execution script mounted from ConfigMap or Volume");
    if let Err(e) = fs::copy(src_path, dest) {
        log_info(&format!("Failed to copy {} to {}: {}", source, dest, e));
        return false;
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(dest).unwrap().permissions();
        perms.set_mode(0o777);
        let _ = fs::set_permissions(dest, perms);
    }

    true
}

fn get_current_rerun(infrakube_generation_path: &str, infrakube_task: &str) -> i32 {
    let tasks = vec![
        "setup", "preinit", "init", "postinit", "preplan", "plan", "postplan", "preapply", "apply",
        "postapply",
    ];

    let task_index = match tasks.iter().position(|&t| t == infrakube_task) {
        Some(idx) => idx,
        None => return 10,
    };

    let entries = match fs::read_dir(infrakube_generation_path) {
        Ok(e) => e,
        Err(_) => return 20,
    };

    let mut filenames = Vec::new();
    for entry in entries.flatten() {
        if let Ok(file_type) = entry.file_type() {
            if file_type.is_file() {
                if let Some(name) = entry.file_name().to_str() {
                    filenames.push(name.to_string());
                }
            }
        }
    }

    let mut prev_task_highest = -1;
    let mut next_task_highest = -1;
    let mut infrakube_task_highest = -1;

    for (i, &task) in tasks.iter().enumerate() {
        let mut temp_highest = -1;
        // Format: <task>.<rerun>.<uuid>.out
        let format_1 = Regex::new(&format!(
            r"^{}\.([0-9]+)\.[0-9a-fA-F]{{8}}-[0-9a-fA-F]{{4}}-[0-9a-fA-F]{{4}}-[0-9a-fA-F]{{4}}-[0-9a-fA-F]{{12}}\.out",
            task
        ))
        .unwrap();
        // Legacy Format: <task>.out
        let format_2 = Regex::new(&format!(r"^{}\.out", task)).unwrap();

        for filename in &filenames {
            if let Some(caps) = format_1.captures(filename) {
                if let Ok(rerun) = caps[1].parse::<i32>() {
                    if rerun > temp_highest {
                        temp_highest = rerun;
                    }
                }
            } else if format_2.is_match(filename) {
                if 0 > temp_highest {
                    temp_highest = 0;
                }
            }
        }

        if i < task_index {
            if temp_highest > prev_task_highest {
                prev_task_highest = temp_highest;
            }
        } else if i == task_index {
            if temp_highest > infrakube_task_highest {
                infrakube_task_highest = temp_highest;
            }
        } else if i > task_index {
            if temp_highest > next_task_highest {
                next_task_highest = temp_highest;
            }
        }
    }

    let mut highest = infrakube_task_highest + 1;
    if prev_task_highest > infrakube_task_highest {
        highest = prev_task_highest;
    }
    if next_task_highest > infrakube_task_highest {
        highest = next_task_highest + 1;
    }
    highest
}

fn run() -> io::Result<i32> {
    if !user_exists() {
        let passwd_path = env_or_panic("PASSWD", false).unwrap_or_else(|| "/etc/passwd".to_string());
        if Path::new(&passwd_path).exists() {
            let mut options = OpenOptions::new();
            options.append(true);
            if let Ok(mut file) = options.open(&passwd_path) {
                let home = env_or_panic("HOME", true).unwrap();
                let username = env_or_panic("USER_NAME", false).unwrap_or_else(|| "infrakube-runner".to_string());
                let uid = unsafe { libc::getuid() };
                let gid = unsafe { libc::getgid() };
                writeln!(
                    file,
                    "{}:x:{}:{}:{} user:{}:/sbin/nologin",
                    username, uid, gid, username, home
                )?;
            }
        }
    }

    let infrakube_task = env_or_panic("INFRAKUBE_TASK", true).unwrap();
    let infrakube_generation = env_or_panic("INFRAKUBE_GENERATION", true).unwrap();
    let infrakube_generation_path = env_or_panic("INFRAKUBE_GENERATION_PATH", true).unwrap();
    let infrakube_main_module_addons = env_or_panic("INFRAKUBE_MAIN_MODULE_ADDONS", false).unwrap_or_default();
    let infrakube_main_module = env_or_panic("INFRAKUBE_MAIN_MODULE", true).unwrap();
    let infrakube_task_exec_inline_source_file = env_or_panic("INFRAKUBE_TASK_EXEC_INLINE_SOURCE_FILE", false).unwrap_or_default();
    let infrakube_task_exec_config_map_source_path = env_or_panic("INFRAKUBE_TASK_EXEC_CONFIGMAP_SOURCE_PATH", false).unwrap_or_default();
    let infrakube_task_exec_config_map_source_key = env_or_panic("INFRAKUBE_TASK_EXEC_CONFIGMAP_SOURCE_KEY", false).unwrap_or_default();
    let infrakube_task_exec_url_source = env_or_panic("INFRAKUBE_TASK_EXEC_URL_SOURCE", false).unwrap_or_default();
    let pod_uid = env_or_panic("POD_UID", false).unwrap_or_else(|| "no-pod-uid".to_string());

    fs::create_dir_all(&infrakube_generation_path)?;
    let current_rerun = get_current_rerun(&infrakube_generation_path, &infrakube_task);
    log_info(&format!("Generation #{} Run: #{}", infrakube_generation, current_rerun));

    let exec_script = format!("{}/{}.sh", infrakube_generation_path, infrakube_task);
    let inline_source = format!("{}/{}", infrakube_main_module_addons, infrakube_task_exec_inline_source_file);
    let config_map_source = format!("{}/{}", infrakube_task_exec_config_map_source_path, infrakube_task_exec_config_map_source_key);

    if !check_set_exec_script(&inline_source, &exec_script) {
        if !check_set_exec_script(&config_map_source, &exec_script) {
            if !infrakube_task_exec_url_source.is_empty() {
                if !download_file(&infrakube_task_exec_url_source, &exec_script) {
                    std::process::exit(1);
                }
            } else {
                log_info("No execution script source provided");
                std::process::exit(1);
            }
        }
    }

    log_info(&format!("Executing {}", exec_script));

    if Path::new(&infrakube_main_module).is_dir() {
        if let Err(e) = env::set_current_dir(&infrakube_main_module) {
            log_info(&format!("Cannot change directory into {}: {}", infrakube_main_module, e));
            return Ok(127);
        }
    }

    let logfile = format!(
        "{}/{}.{}.{}.out",
        infrakube_generation_path, infrakube_task, current_rerun, pod_uid
    );

    log_info(&format!("Logging to {}", logfile));
    log_info("Streaming results from execution:");

    let mut child = Command::new("/bin/bash")
        .arg(&exec_script)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;

    let stdout = child.stdout.take().expect("Failed to capture stdout");
    let stderr = child.stderr.take().expect("Failed to capture stderr");

    let mut log_file_writer = File::create(&logfile)?;

    let (tx, rx) = std::sync::mpsc::channel();

    let tx_stdout = tx.clone();
    let stdout_handle = thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        let mut buffer = [0; 1024];
        while let Ok(n) = reader.read(&mut buffer) {
            if n == 0 {
                break;
            }
            let _ = tx_stdout.send(buffer[..n].to_vec());
        }
    });

    let tx_stderr = tx;
    let stderr_handle = thread::spawn(move || {
        let mut reader = BufReader::new(stderr);
        let mut buffer = [0; 1024];
        while let Ok(n) = reader.read(&mut buffer) {
            if n == 0 {
                break;
            }
            let _ = tx_stderr.send(buffer[..n].to_vec());
        }
    });

    for data in rx {
        io::stdout().write_all(&data)?;
        log_file_writer.write_all(&data)?;
        io::stdout().flush()?;
        log_file_writer.flush()?;
    }

    stdout_handle.join().expect("Stdout thread panicked");
    stderr_handle.join().expect("Stderr thread panicked");

    let status = child.wait()?;
    println!();
    Ok(status.code().unwrap_or(1))
}

fn main() {
    match run() {
        Ok(code) => std::process::exit(code),
        Err(e) => {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
    }
}
