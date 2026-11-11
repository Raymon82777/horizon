//! A controller the platform reads itself, for systems gilrs has no backend for (iOS, where
//! Apple's GameController framework is the only way to a pad). The platform's own code calls
//! [`connect`], [`set_state`] and [`disconnect`] from whichever thread its events arrive on;
//! the game reads [`read`] and [`take_changes`] once per frame, beside its own reader.
//!
//! One pad at a time: the one the platform calls current.
use super::{GlyphStyle, PadState};
use std::sync::{Mutex, MutexGuard, PoisonError};

/// A controller that came or went since the last [`take_changes`].
#[derive(Clone, Debug, PartialEq)]
pub enum Change {
    Connected { style: GlyphStyle, name: String },
    Disconnected,
}

/// The platform's controller as the game reads it.
#[derive(Clone, Debug, PartialEq)]
pub struct Pad {
    pub state: PadState,
    pub style: GlyphStyle,
    pub name: String,
}

#[derive(Default)]
struct Feed {
    pad: Option<Pad>,
    changes: Vec<Change>,
}

static FEED: Mutex<Feed> = Mutex::new(Feed {
    pad: None,
    changes: Vec::new(),
});

/// A lock a panic elsewhere never makes unusable: the state stays consistent between calls.
fn feed() -> MutexGuard<'static, Feed> {
    FEED.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A controller of this family is now the platform's current one, at rest.
pub fn connect(style: GlyphStyle, name: &str) {
    let mut feed = feed();
    feed.pad = Some(Pad {
        state: PadState::default(),
        style,
        name: name.to_owned(),
    });
    feed.changes.push(Change::Connected {
        style,
        name: name.to_owned(),
    });
}

/// The current controller went away: everything it held lets go.
pub fn disconnect() {
    let mut feed = feed();
    if feed.pad.take().is_some() {
        feed.changes.push(Change::Disconnected);
    }
}

/// The current controller's whole state (ignored with none connected).
pub fn set_state(state: PadState) {
    if let Some(pad) = feed().pad.as_mut() {
        pad.state = state;
    }
}

/// The platform's controller, if one is connected.
pub fn read() -> Option<Pad> {
    feed().pad.clone()
}

/// The controllers that came and went since the last call.
pub fn take_changes() -> Vec<Change> {
    std::mem::take(&mut feed().changes)
}

#[cfg(test)]
mod tests {
    use super::super::Button;
    use super::*;

    // One test: the feed is process-wide, and parallel tests would see each other's pads.
    #[test]
    fn a_pad_comes_plays_and_goes() {
        let _ = take_changes();
        disconnect();
        let _ = take_changes();

        // Nothing connected: a state has nowhere to go.
        let mut held = PadState::default();
        held.set(Button::South, true);
        set_state(held);
        assert_eq!(read(), None);

        connect(GlyphStyle::PlayStation, "DualSense");
        assert_eq!(read().map(|p| p.state), Some(PadState::default()));
        set_state(held);
        let pad = read().expect("connected");
        assert!(pad.state.held(Button::South));
        assert_eq!(pad.style, GlyphStyle::PlayStation);

        disconnect();
        assert_eq!(read(), None);
        // A second disconnect isn't news.
        disconnect();
        assert_eq!(
            take_changes(),
            vec![
                Change::Connected {
                    style: GlyphStyle::PlayStation,
                    name: "DualSense".into()
                },
                Change::Disconnected,
            ]
        );
        assert_eq!(take_changes(), vec![]);
    }
}
