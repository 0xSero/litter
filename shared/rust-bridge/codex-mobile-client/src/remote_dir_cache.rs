//! Process-wide caches for the directory picker.
//!
//! Every picker open used to pay two serial `command/exec` round trips
//! (home lookup, then listing) and every folder tap paid another. Home
//! directories never change for a server, and listings change rarely, so
//! both are cached here and served without a round trip.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

/// How long a directory listing is served without asking the host again.
pub const LISTING_TTL: Duration = Duration::from_secs(30);
const MAX_LISTINGS: usize = 512;

struct Caches {
    homes: HashMap<String, String>,
    listings: HashMap<(String, String), (Instant, Vec<String>)>,
}

fn caches() -> &'static Mutex<Caches> {
    static CACHES: OnceLock<Mutex<Caches>> = OnceLock::new();
    CACHES.get_or_init(|| {
        Mutex::new(Caches {
            homes: HashMap::new(),
            listings: HashMap::new(),
        })
    })
}

pub fn home(server_id: &str) -> Option<String> {
    caches().lock().ok()?.homes.get(server_id).cloned()
}

pub fn store_home(server_id: &str, home: &str) {
    if let Ok(mut c) = caches().lock() {
        c.homes.insert(server_id.to_string(), home.to_string());
    }
}

pub fn listing(server_id: &str, path: &str) -> Option<Vec<String>> {
    let c = caches().lock().ok()?;
    let (at, dirs) = c.listings.get(&(server_id.to_string(), path.to_string()))?;
    (at.elapsed() < LISTING_TTL).then(|| dirs.clone())
}

pub fn store_listing(server_id: &str, path: &str, dirs: &[String]) {
    if let Ok(mut c) = caches().lock() {
        if c.listings.len() >= MAX_LISTINGS {
            c.listings.retain(|_, (at, _)| at.elapsed() < LISTING_TTL);
            if c.listings.len() >= MAX_LISTINGS {
                c.listings.clear();
            }
        }
        c.listings.insert(
            (server_id.to_string(), path.to_string()),
            (Instant::now(), dirs.to_vec()),
        );
    }
}

/// Drop cached listings for `server_id` (after creating a directory, or on
/// reconnect). Home paths are kept.
pub fn invalidate_listings(server_id: &str) {
    if let Ok(mut c) = caches().lock() {
        c.listings.retain(|(s, _), _| s != server_id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn caches_home_and_listing_per_server() {
        store_home("cache-test-a", "/home/a");
        assert_eq!(home("cache-test-a").as_deref(), Some("/home/a"));
        assert_eq!(home("cache-test-b"), None);

        store_listing("cache-test-a", "/home/a", &["src".into()]);
        assert_eq!(listing("cache-test-a", "/home/a"), Some(vec!["src".into()]));
        assert_eq!(listing("cache-test-b", "/home/a"), None);

        invalidate_listings("cache-test-a");
        assert_eq!(listing("cache-test-a", "/home/a"), None);
        assert_eq!(home("cache-test-a").as_deref(), Some("/home/a"));
    }
}
