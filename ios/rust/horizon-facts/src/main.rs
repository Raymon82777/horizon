//! `horizon-facts pack-facts …` (on a computer with a prepared resources folder) and
//! `horizon-facts assemble …` (anywhere): see the library docs.

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match horizon_facts::cli(&args) {
        Some(Ok(())) => ExitCode::SUCCESS,
        Some(Err(e)) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
        None => {
            eprintln!(
                "usage: horizon-facts pack-facts --resources DIR --client-jar JAR --assets-dir DIR [--asset-index 34] [--version 26.3] --out ZIP\n       horizon-facts assemble --facts ZIP --client-jar JAR --assets-dir DIR --out DIR"
            );
            ExitCode::FAILURE
        }
    }
}
