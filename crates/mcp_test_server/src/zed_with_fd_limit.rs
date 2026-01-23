//! Wrapper to run Zed with a limited file descriptor count
//!
//! This uses setrlimit to set RLIMIT_NOFILE before exec'ing Zed,
//! which is safer than changing global limits.
//!
//! Usage:
//!   cargo run --bin zed-with-fd-limit -- [fd_limit]
//!
//! Example:
//!   cargo run --bin zed-with-fd-limit -- 256

use std::env;
use std::process::Command;

#[cfg(unix)]
fn set_fd_limit(limit: u64) -> std::io::Result<()> {
    use std::io::{Error, ErrorKind};

    // Get current limits
    let mut rlimit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };

    unsafe {
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut rlimit) != 0 {
            return Err(Error::last_os_error());
        }
    }

    eprintln!(
        "Current FD limits: soft={}, hard={}",
        rlimit.rlim_cur, rlimit.rlim_max
    );

    // Set new limits (both soft and hard to the requested value)
    let new_rlimit = libc::rlimit {
        rlim_cur: limit,
        rlim_max: limit.max(rlimit.rlim_max), // Don't lower hard limit below current
    };

    unsafe {
        if libc::setrlimit(libc::RLIMIT_NOFILE, &new_rlimit) != 0 {
            let err = Error::last_os_error();
            eprintln!("Warning: Failed to set FD limit to {}: {}", limit, err);

            // Try setting just the soft limit
            let soft_only = libc::rlimit {
                rlim_cur: limit.min(rlimit.rlim_max),
                rlim_max: rlimit.rlim_max,
            };

            if libc::setrlimit(libc::RLIMIT_NOFILE, &soft_only) != 0 {
                return Err(Error::new(
                    ErrorKind::Other,
                    format!("Failed to set FD limit: {}", err),
                ));
            }

            eprintln!(
                "Set soft limit to {} (hard limit unchanged at {})",
                soft_only.rlim_cur, soft_only.rlim_max
            );
        } else {
            eprintln!(
                "Successfully set FD limit to: soft={}, hard={}",
                new_rlimit.rlim_cur, new_rlimit.rlim_max
            );
        }
    }

    Ok(())
}

#[cfg(not(unix))]
fn set_fd_limit(_limit: u64) -> std::io::Result<()> {
    eprintln!("Warning: FD limit setting not supported on this platform");
    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().collect();

    // Parse FD limit from command line (default 256)
    let fd_limit = if args.len() > 1 {
        args[1].parse::<u64>().unwrap_or_else(|_| {
            eprintln!("Invalid FD limit '{}', using default 256", args[1]);
            256
        })
    } else {
        256
    };

    eprintln!("=================================================");
    eprintln!("Zed with FD Limit Wrapper");
    eprintln!("=================================================");
    eprintln!("Target FD limit: {}", fd_limit);
    eprintln!();

    // Set the FD limit
    if let Err(e) = set_fd_limit(fd_limit) {
        eprintln!("Error setting FD limit: {}", e);
        std::process::exit(1);
    }

    eprintln!();
    eprintln!("Starting Zed...");
    eprintln!("=================================================");
    eprintln!();

    // Find Zed binary
    let zed_path = if cfg!(debug_assertions) {
        "./target/debug/zed"
    } else {
        "./target/release/zed"
    };

    // Check if Zed exists
    if !std::path::Path::new(zed_path).exists() {
        eprintln!("Error: Zed binary not found at {}", zed_path);
        eprintln!("Please build Zed first:");
        eprintln!("  cargo build --release");
        std::process::exit(1);
    }

    // Execute Zed, replacing this process
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;

        let err = Command::new(zed_path).exec(); // This replaces the current process

        // If we get here, exec failed
        eprintln!("Failed to execute Zed: {}", err);
        std::process::exit(1);
    }

    #[cfg(not(unix))]
    {
        // On Windows, just spawn the process
        let status = Command::new(zed_path)
            .status()
            .expect("Failed to execute Zed");

        std::process::exit(status.code().unwrap_or(1));
    }
}
