//! ios: touch controls (Raymon82777/horizon-ios's iOS fork; not upstream). Fingers on the screen
//! drive the game through the same paths a controller does: the move vector (`input_move`),
//! the view turn (`input_look`) and the bound actions (`pad_action`), so every mapping and
//! rule the pad follows holds for touch too. Out of play (title, menus, inventories) a finger is
//! the mouse: it moves the pointer and holds the left button.
//!
//! In play, with the upstream touch layout (`horizon_client_render::touch::layout`, crosshair scheme):
//! a finger on the left part of the screen is a joystick from where it lands; anywhere else it
//! drags the view, a quick tap there uses (places, opens) and a still hold attacks (mines). The
//! layout's buttons jump, sneak (a toggle), sprint, attack, use, open the inventory, chat, pause
//! and switch the camera; a tap on the hotbar selects that slot.
//!
//! State lives in a thread-local (the game runs on the main thread) so the upstream `Game`
//! struct stays untouched.
use super::*;
use horizon_client_render::touch::{aim, layout};
use layout::Control;
use std::cell::RefCell;
use winit::dpi::PhysicalPosition;
use winit::event::{Touch, TouchPhase};

/// How far left a finger may land to start the joystick (fraction of the width).
const JOYSTICK_AREA: f32 = 0.4;
/// A tap on the world: shorter than this, and moving less than [`STILL`].
const TAP: Duration = Duration::from_millis(250);
/// A finger held this long on the world without moving starts attacking.
const HOLD: Duration = Duration::from_millis(350);
/// How far a finger may drift (fraction of the height) and still count as still.
const STILL: f32 = 0.025;

/// One finger and what it does.
#[derive(Clone, Copy)]
enum Role {
    /// Out of play: the mouse pointer. The left button goes down once the finger moves (a
    /// drag) or lifts (a tap), so a second finger landing first can make it a scroll instead.
    Pointer { start: [f32; 2], pressed: bool },
    /// Out of play: two fingers dragging scroll what's under them, as a mouse wheel.
    Scroll,
    /// The joystick, from where the finger landed (pixels).
    Joystick { origin: [f32; 2] },
    /// Turning the view; a tap uses, a still hold attacks.
    Look {
        start: Instant,
        last: [f32; 2],
        drift: f32,
        attacking: bool,
    },
    /// A held layout button.
    Button(Control),
    /// Swallowed (a hotbar tap, a second pointer finger).
    Ignored,
}

#[derive(Default)]
struct State {
    /// Set once a finger touches the screen: until then nothing draws or acts.
    seen: bool,
    fingers: Vec<(u64, Role, [f32; 2])>,
    settings: Option<layout::Settings>,
    sneaking: bool,
    /// Bound actions the touch controls hold (`input_holds`).
    held: Vec<&'static str>,
    /// The scrolling fingers' midpoint last time (pixels).
    scroll_from: Option<[f32; 2]>,
}

/// The touch layout the launcher's editor writes (`horizon_client_render::touch::layout::Settings`
/// as JSON): one for every instance, in the app's Documents. The game runs in the instance's
/// folder (`--game-dir`), so the path isn't relative to it.
fn layout_file() -> std::path::PathBuf {
    match std::env::var_os("HOME") {
        Some(home) => std::path::Path::new(&home).join("Documents/touch-controls.json"),
        None => "touch-controls.json".into(),
    }
}

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State::default());
}

fn with<T>(f: impl FnOnce(&mut State) -> T) -> T {
    STATE.with(|s| {
        let mut s = s.borrow_mut();
        if s.settings.is_none() {
            s.settings = Some(layout::Settings::load(&layout_file()));
        }
        f(&mut s)
    })
}

/// Where `control` sits on a `size` screen. The layout is made for landscape (sizes are
/// fractions of the height); in portrait the sizes go by the short side so buttons stay the same
/// size, and the top row moves below the Dynamic Island.
fn placed(settings: &layout::Settings, control: Control, size: [f32; 2]) -> layout::Placement {
    let mut p = settings.placement(control);
    if size[1] > size[0] {
        p.size *= size[0] / size[1];
        p.center[1] = p.center[1].max(0.085);
    }
    p
}

/// What a layout button is bound to, and its label.
fn binding(control: Control) -> Option<(&'static str, &'static str)> {
    Some(match control {
        Control::Jump => ("key.jump", "Jump"),
        Control::Sneak => ("key.sneak", "Sneak"),
        Control::Sprint => ("key.sprint", "Sprint"),
        Control::Attack => ("key.attack", "Hit"),
        Control::Use => ("key.use", "Use"),
        Control::Inventory => ("key.inventory", "Inv"),
        Control::Chat => ("key.chat", "Chat"),
        Control::Pause => ("pause", "II"),
        Control::Perspective => ("key.togglePerspective", "F5"),
        Control::Shield => ("key.use", "Shield"),
        Control::Offhand => ("key.swapOffhand", "Swap"),
        Control::Move | Control::Settings | Control::Debug => return None,
    })
}

impl Game<'_> {
    fn touch_surface(&self) -> Option<[f32; 2]> {
        let r = self.renderer.as_ref()?;
        Some([r.config.width as f32, r.config.height as f32])
    }

    fn touch_playing(&self) -> bool {
        self.title.is_none() && self.screen == Screen::Playing && self.player.is_some()
    }

    fn touch_act(&mut self, action: &'static str, down: bool) {
        with(|s| {
            s.held.retain(|a| *a != action);
            if down {
                s.held.push(action);
            }
        });
        let result = if action == "pause" {
            if down { self.pad_back() } else { Ok(()) }
        } else {
            self.pad_action(action, down)
        };
        if let Err(e) = result {
            log::warn!("Horizon: touch {action}: {e}");
        }
    }

    /// The pointer at `at` (surface pixels), as the window's mouse would move it.
    fn touch_pointer(&mut self, event_loop: &dyn EventLoopCtl, at: [f32; 2], press: Option<bool>) {
        let Some(id) = self.window.as_ref().map(|w| w.id()) else {
            return;
        };
        let device_id = winit::event::DeviceId::dummy();
        let position = PhysicalPosition::new(f64::from(at[0]), f64::from(at[1]));
        let origin = input_trace::InputOrigin::User;
        self.handle_window_event(
            event_loop,
            id,
            WindowEvent::CursorMoved {
                device_id,
                position,
            },
            origin,
        );
        if let Some(down) = press {
            let state = if down {
                ElementState::Pressed
            } else {
                ElementState::Released
            };
            self.handle_window_event(
                event_loop,
                id,
                WindowEvent::MouseInput {
                    device_id,
                    state,
                    button: MouseButton::Left,
                },
                origin,
            );
        }
    }

    /// A mouse wheel turn of `dy` pixels (positive: up), the pointer at `at`.
    fn touch_wheel(&mut self, event_loop: &dyn EventLoopCtl, at: [f32; 2], dy: f32) {
        let Some(id) = self.window.as_ref().map(|w| w.id()) else {
            return;
        };
        self.touch_pointer(event_loop, at, None);
        self.handle_window_event(
            event_loop,
            id,
            WindowEvent::MouseWheel {
                device_id: winit::event::DeviceId::dummy(),
                delta: winit::event::MouseScrollDelta::PixelDelta(PhysicalPosition::new(
                    0.0,
                    f64::from(dy),
                )),
                phase: TouchPhase::Moved,
            },
            input_trace::InputOrigin::User,
        );
    }

    /// The scrolling fingers' midpoint.
    fn touch_scroll_mid() -> Option<[f32; 2]> {
        with(|s| {
            let points: Vec<[f32; 2]> = s
                .fingers
                .iter()
                .filter(|f| matches!(f.1, Role::Scroll))
                .map(|f| f.2)
                .collect();
            (!points.is_empty()).then(|| {
                let n = points.len() as f32;
                [
                    points.iter().map(|p| p[0]).sum::<f32>() / n,
                    points.iter().map(|p| p[1]).sum::<f32>() / n,
                ]
            })
        })
    }

    /// The layout button under `at` (surface pixels), if one shows there.
    fn touch_button_at(&self, at: [f32; 2], size: [f32; 2]) -> Option<Control> {
        let point = [at[0] / size[0], at[1] / size[1]];
        let aspect = size[0] / size[1];
        with(|s| {
            let settings = s.settings.as_ref()?;
            Control::ALL.into_iter().find(|c| {
                binding(*c).is_some()
                    && settings.visible(*c)
                    && layout::contains(placed(settings, *c, size).rect(aspect), point)
            })
        })
    }

    /// winit's `WindowEvent::Touch`.
    pub(super) fn touch_event(&mut self, event_loop: &dyn EventLoopCtl, touch: Touch) {
        let Some(size) = self.touch_surface() else {
            return;
        };
        let at = [touch.location.x as f32, touch.location.y as f32];
        self.last_input = Instant::now();
        match touch.phase {
            TouchPhase::Started => {
                // A finger takes over from a controller, as the mouse does.
                self.pad_yield_input(event_loop);
                self.touch_started(event_loop, touch.id, at, size)
            }
            TouchPhase::Moved => self.touch_moved(event_loop, touch.id, at, size),
            TouchPhase::Ended | TouchPhase::Cancelled => {
                self.touch_ended(event_loop, touch.id, at, touch.phase == TouchPhase::Ended)
            }
        }
    }

    fn touch_started(
        &mut self,
        event_loop: &dyn EventLoopCtl,
        id: u64,
        at: [f32; 2],
        size: [f32; 2],
    ) {
        let roles: Vec<Role> = with(|s| {
            s.seen = true;
            s.fingers.iter().map(|f| f.1).collect()
        });
        // The keyboard's Hide put it away while a text box still has focus: a tap brings it back.
        if self.ime_allowed
            && let Some(window) = &self.window
        {
            window.set_ime_allowed(true);
        }
        let role = if !self.touch_playing() {
            if roles
                .iter()
                .any(|r| matches!(r, Role::Pointer { pressed: false, .. }))
            {
                // A second finger before the first did anything: the two scroll.
                with(|s| {
                    for f in &mut s.fingers {
                        if matches!(f.1, Role::Pointer { .. }) {
                            f.1 = Role::Scroll;
                        }
                    }
                });
                Role::Scroll
            } else if roles
                .iter()
                .any(|r| matches!(r, Role::Pointer { .. } | Role::Scroll))
            {
                Role::Ignored
            } else {
                self.touch_pointer(event_loop, at, None);
                Role::Pointer {
                    start: at,
                    pressed: false,
                }
            }
        } else {
            if !self.captured && self.focused {
                // Like a click into the window: play takes the pointer.
                self.capture(true);
            }
            let gui = HudBatch::new([size[0] as u32, size[1] as u32]);
            let gui_point = [at[0] / gui.scale, at[1] / gui.scale];
            if let Some(control) = self.touch_button_at(at, size) {
                let (action, _) = binding(control).unwrap_or(("", ""));
                if control == Control::Sneak {
                    let on = with(|s| {
                        s.sneaking = !s.sneaking;
                        s.sneaking
                    });
                    self.touch_act(action, on);
                } else {
                    self.touch_act(action, true);
                }
                Role::Button(control)
            } else if let Some(slot) = aim::hotbar_slot(gui.width, gui.height, gui_point) {
                let action = HOTBAR_ACTIONS[slot.min(8)];
                self.touch_act(action, true);
                self.touch_act(action, false);
                Role::Ignored
            } else if at[0] < size[0] * JOYSTICK_AREA
                && !roles.iter().any(|r| matches!(r, Role::Joystick { .. }))
            {
                Role::Joystick { origin: at }
            } else if !roles.iter().any(|r| matches!(r, Role::Look { .. })) {
                Role::Look {
                    start: Instant::now(),
                    last: at,
                    drift: 0.0,
                    attacking: false,
                }
            } else {
                Role::Ignored
            }
        };
        with(|s| s.fingers.push((id, role, at)));
        if matches!(role, Role::Scroll) {
            let mid = Self::touch_scroll_mid();
            with(|s| s.scroll_from = mid);
        }
    }

    fn touch_moved(
        &mut self,
        event_loop: &dyn EventLoopCtl,
        id: u64,
        at: [f32; 2],
        size: [f32; 2],
    ) {
        let Some(role) = with(|s| {
            let finger = s.fingers.iter_mut().find(|f| f.0 == id)?;
            finger.2 = at;
            Some(finger.1)
        }) else {
            return;
        };
        match role {
            Role::Pointer {
                start,
                pressed: false,
            } => {
                if (at[0] - start[0]).hypot(at[1] - start[1]) / size[1] > STILL {
                    // A drag: the button goes down where the finger landed.
                    self.touch_pointer(event_loop, start, Some(true));
                    self.touch_pointer(event_loop, at, None);
                    with(|s| {
                        if let Some(f) = s.fingers.iter_mut().find(|f| f.0 == id) {
                            f.1 = Role::Pointer {
                                start,
                                pressed: true,
                            };
                        }
                    });
                }
            }
            Role::Pointer { pressed: true, .. } => self.touch_pointer(event_loop, at, None),
            Role::Scroll => {
                let (Some(mid), Some(from)) = (Self::touch_scroll_mid(), with(|s| s.scroll_from))
                else {
                    return;
                };
                with(|s| s.scroll_from = Some(mid));
                // Natural scrolling: the list follows the fingers.
                self.touch_wheel(event_loop, mid, mid[1] - from[1]);
            }
            Role::Look {
                start,
                last,
                drift,
                attacking,
            } => {
                let delta = [(at[0] - last[0]) / size[0], (at[1] - last[1]) / size[1]];
                let drift = drift + (at[0] - last[0]).hypot(at[1] - last[1]) / size[1];
                with(|s| {
                    if let Some(f) = s.fingers.iter_mut().find(|f| f.0 == id) {
                        f.1 = Role::Look {
                            start,
                            last: at,
                            drift,
                            attacking,
                        };
                    }
                });
                if self.touch_playing() {
                    let turn = with(|s| {
                        let settings = s.settings.as_ref().expect("touch settings");
                        aim::camera_delta(delta, size[0] as u32, size[1] as u32, settings)
                    });
                    self.look_turn(f64::from(turn[0] / 0.15), f64::from(turn[1] / 0.15));
                }
            }
            Role::Joystick { .. } | Role::Button(_) | Role::Ignored => {}
        }
    }

    fn touch_ended(&mut self, event_loop: &dyn EventLoopCtl, id: u64, at: [f32; 2], ended: bool) {
        let Some(role) = with(|s| {
            let i = s.fingers.iter().position(|f| f.0 == id)?;
            Some(s.fingers.remove(i).1)
        }) else {
            return;
        };
        match role {
            Role::Pointer {
                start,
                pressed: false,
            } => {
                // A tap: a click where the finger landed.
                if ended {
                    self.touch_pointer(event_loop, start, Some(true));
                    self.touch_pointer(event_loop, start, Some(false));
                }
            }
            Role::Pointer { pressed: true, .. } => self.touch_pointer(event_loop, at, Some(false)),
            Role::Scroll => {
                let mid = Self::touch_scroll_mid();
                with(|s| s.scroll_from = mid);
            }
            Role::Look {
                start,
                drift,
                attacking,
                ..
            } => {
                if attacking {
                    self.touch_act("key.attack", false);
                } else if ended && start.elapsed() < TAP && drift < STILL && self.touch_playing() {
                    self.touch_act("key.use", true);
                    self.touch_act("key.use", false);
                }
            }
            Role::Button(Control::Sneak) => {}
            Role::Button(control) => {
                if let Some((action, _)) = binding(control) {
                    self.touch_act(action, false);
                }
            }
            Role::Joystick { .. } | Role::Ignored => {}
        }
    }

    /// The joystick's move vector (`[left, forward]`), while a finger holds it in play.
    pub(super) fn touch_move(&self) -> Option<[f32; 2]> {
        if !self.touch_playing() {
            return None;
        }
        let size = self.touch_surface()?;
        with(|s| {
            let radius = placed(s.settings.as_ref()?, Control::Move, size).size / 2.0 * size[1];
            s.fingers.iter().find_map(|(_, role, at)| match role {
                Role::Joystick { origin } => {
                    let v = [(at[0] - origin[0]) / radius, (at[1] - origin[1]) / radius];
                    let length = v[0].hypot(v[1]);
                    if length < 0.12 {
                        return Some([0.0, 0.0]);
                    }
                    let k = 1.0 / length.max(1.0);
                    Some([-v[0] * k, -v[1] * k])
                }
                _ => None,
            })
        })
    }

    /// Whether the touch controls hold the bound action `mapping`.
    pub(super) fn touch_holds(&self, mapping: &str) -> bool {
        STATE.with(|s| s.borrow().held.iter().any(|a| *a == mapping))
    }

    /// Each frame: a finger held still on the world starts attacking.
    pub(super) fn touch_frame(&mut self) {
        let start_attack = with(|s| {
            let mut start = false;
            for f in &mut s.fingers {
                if let Role::Look {
                    start: began,
                    drift,
                    attacking,
                    ..
                } = &mut f.1
                    && !*attacking
                    && *drift < STILL
                    && began.elapsed() >= HOLD
                {
                    *attacking = true;
                    start = true;
                }
            }
            start
        });
        if start_attack && self.touch_playing() {
            self.touch_act("key.attack", true);
        }
    }

    /// The touch controls over the HUD, in play, once a finger has touched the screen.
    pub(super) fn draw_touch_over_hud(&self, batch: &mut HudBatch) {
        // A controller playing hides them until a finger is back on the screen.
        if !self.touch_playing() || !with(|s| s.seen) || self.pad.in_use {
            return;
        }
        let Some(size) = self.touch_surface() else {
            return;
        };
        let atlas = &self.gui.atlas;
        let (w, h) = (batch.width, batch.height);
        let aspect = size[0] / size[1];
        let to_gui = |p: [f32; 2]| [p[0] / size[0] * w, p[1] / size[1] * h];
        with(|s| {
            let Some(settings) = s.settings.as_ref() else {
                return;
            };
            let held: Vec<Control> = s
                .fingers
                .iter()
                .filter_map(|f| match f.1 {
                    Role::Button(c) => Some(c),
                    _ => None,
                })
                .collect();
            for control in Control::ALL {
                let Some((_, label)) = binding(control) else {
                    continue;
                };
                if !settings.visible(control) {
                    continue;
                }
                let p = placed(settings, control, size);
                let [x, y, bw, bh] = p.rect(aspect);
                let centre = [(x + bw / 2.0) * w, (y + bh / 2.0) * h];
                let radius = bh * h / 2.0;
                let lit = held.contains(&control) || (control == Control::Sneak && s.sneaking);
                let alpha = (p.opacity * if lit { 255.0 } else { 150.0 }) as u32;
                let fill = (alpha << 24) | if lit { 0x00_60_60_60 } else { 0x00_20_20_20 };
                batch.fill_disc(atlas, centre, radius, fill);
                let tw = HudBatch::text_width(atlas, label);
                batch.text(
                    atlas,
                    label,
                    (centre[0] - tw / 2.0).round(),
                    (centre[1] - 4.0).round(),
                    0xE0_FF_FF_FF,
                    true,
                );
            }
            // The joystick: where the finger landed, else its resting place.
            let move_p = placed(settings, Control::Move, size);
            let radius = move_p.size / 2.0 * h;
            let (base, knob) = s
                .fingers
                .iter()
                .find_map(|(_, role, at)| match role {
                    Role::Joystick { origin } => {
                        let (b, k) = (to_gui(*origin), to_gui(*at));
                        let d = [k[0] - b[0], k[1] - b[1]];
                        let l = d[0].hypot(d[1]).max(radius) / radius;
                        Some((b, [b[0] + d[0] / l, b[1] + d[1] / l]))
                    }
                    _ => None,
                })
                .unwrap_or_else(|| {
                    let c = [move_p.center[0] * w, move_p.center[1] * h];
                    (c, c)
                });
            batch.fill_disc(atlas, base, radius, 0x50_20_20_20);
            batch.fill_disc(atlas, knob, radius * 0.42, 0xA0_C0_C0_C0);
        });
    }
}

const HOTBAR_ACTIONS: [&str; 9] = [
    "key.hotbar.1",
    "key.hotbar.2",
    "key.hotbar.3",
    "key.hotbar.4",
    "key.hotbar.5",
    "key.hotbar.6",
    "key.hotbar.7",
    "key.hotbar.8",
    "key.hotbar.9",
];
