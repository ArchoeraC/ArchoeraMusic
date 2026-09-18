//! 输入事件处理：键盘（含媒体键）、指针（相对/绝对）、滚轮。
//!
//! kiosk 语义下没有多窗口堆叠：点击即把焦点交给命中的窗口（通常只有播放器一个）。
//! 媒体键（音量/播放/上一首/下一首）在**转发给客户端的同时**额外经
//! `archoera_shell_v1` 广播 `media_key` 事件，使尚未实现该协议的客户端也能照常
//! 收到按键，而实现了协议的会话可据此驱动系统级行为。

use smithay::{
    backend::input::{
        AbsolutePositionEvent, Axis, AxisSource, ButtonState, Event, InputBackend, InputEvent,
        KeyState, KeyboardKeyEvent, PointerAxisEvent, PointerButtonEvent, PointerMotionEvent,
        TouchEvent,
    },
    input::{
        keyboard::{FilterResult, Keycode},
        pointer::{AxisFrame, ButtonEvent, MotionEvent},
        touch::{DownEvent as TouchDown, MotionEvent as TouchMove, UpEvent as TouchUp},
    },
    utils::{Logical, Point, SERIAL_COUNTER},
};

use crate::{
    protocol::{MediaKey, PowerKey},
    state::ArchoeraShell,
};

impl ArchoeraShell {
    /// 处理来自任一输入后端的事件。
    pub fn process_input_event<I: InputBackend>(&mut self, event: InputEvent<I>) {
        match event {
            InputEvent::Keyboard { event, .. } => {
                let keycode = event.key_code();
                let key_state = event.state();

                // 媒体键：先广播给会话，再照常转发（兼容未实现协议的客户端）。
                if key_state == KeyState::Pressed {
                    if let Some(key) = media_key_for(keycode) {
                        self.notify_media_key(key);
                    }
                    if let Some(key) = power_key_for(keycode) {
                        self.notify_power_key(key);
                    }
                }

                let serial = SERIAL_COUNTER.next_serial();
                let time = Event::time_msec(&event);
                // Ctrl+Alt+Fn → 切换 VT。DRM/KMS 会话处于 KD_GRAPHICS 时内核不再处理这组
                // 组合键（图形模式下由显示服务负责），所以必须我们自己转发给 libseat/logind，
                // 否则用户永远切不到 tty（安装器的 tty2 也进不去、无法排查问题）。
                // 注意 keycode 是 XKB 码：F1 = 67 … F12 = 78（evdev + 8）。
                let vt_switch =
                    if key_state == KeyState::Pressed && (67..=78).contains(&keycode.raw()) {
                        Some(keycode.raw() as i32 - 66)
                    } else {
                        None
                    };
                self.seat.get_keyboard().unwrap().input::<(), _>(
                    self,
                    keycode,
                    key_state,
                    serial,
                    time,
                    move |state, mods, _| {
                        if let Some(vt) = vt_switch {
                            if mods.ctrl && mods.alt {
                                if let Some(backend) = state.backend.as_mut() {
                                    if let Err(err) = backend.change_vt(vt) {
                                        tracing::warn!(%err, vt, "切换 VT 失败");
                                    }
                                }
                                return FilterResult::Intercept(());
                            }
                        }
                        FilterResult::Forward
                    },
                );
            }
            InputEvent::PointerMotion { event, .. } => {
                let pointer = self.seat.get_pointer().unwrap();
                let previous = pointer.current_location();
                let mut location = previous + event.delta();
                self.clamp_pointer(&mut location);

                let serial = SERIAL_COUNTER.next_serial();
                let under = self.surface_under(location);
                pointer.motion(
                    self,
                    under,
                    &MotionEvent {
                        location,
                        serial,
                        time: event.time_msec(),
                    },
                );
                pointer.frame(self);

                // 指针位置变化即需重绘（光标跟随）；未移动则不触发。
                if location != previous {
                    self.cursor.set_location(location);
                    self.mark_dirty();
                    self.schedule_redraw();
                }
            }
            InputEvent::PointerMotionAbsolute { event, .. } => {
                let Some(output) = self.space.outputs().next() else {
                    return;
                };
                let Some(output_geo) = self.space.output_geometry(output) else {
                    return;
                };
                let mut location =
                    event.position_transformed(output_geo.size) + output_geo.loc.to_f64();
                self.clamp_pointer(&mut location);

                let serial = SERIAL_COUNTER.next_serial();
                let pointer = self.seat.get_pointer().unwrap();
                let previous = pointer.current_location();
                let under = self.surface_under(location);
                pointer.motion(
                    self,
                    under,
                    &MotionEvent {
                        location,
                        serial,
                        time: event.time_msec(),
                    },
                );
                pointer.frame(self);

                if location != previous {
                    self.cursor.set_location(location);
                    self.mark_dirty();
                    self.schedule_redraw();
                }
            }
            InputEvent::PointerButton { event, .. } => {
                let pointer = self.seat.get_pointer().unwrap();
                let serial = SERIAL_COUNTER.next_serial();
                let button = event.button_code();
                let button_state = event.state();

                if ButtonState::Pressed == button_state && !pointer.is_grabbed() {
                    let hit = self
                        .space
                        .element_under(pointer.current_location())
                        .map(|(w, _)| w.clone());
                    if let Some(window) = hit {
                        self.space.raise_element(&window, true);
                        if let Some(toplevel) = window.toplevel() {
                            self.seat.get_keyboard().unwrap().set_focus(
                                self,
                                Some(toplevel.wl_surface().clone()),
                                serial,
                            );
                        }
                    }
                }

                pointer.button(
                    self,
                    &ButtonEvent {
                        button,
                        state: button_state,
                        serial,
                        time: event.time_msec(),
                    },
                );
                pointer.frame(self);
            }
            InputEvent::PointerAxis { event, .. } => {
                let source = event.source();
                let horizontal_amount = event.amount(Axis::Horizontal).unwrap_or_else(|| {
                    event.amount_v120(Axis::Horizontal).unwrap_or(0.0) * 15.0 / 120.
                });
                let vertical_amount = event.amount(Axis::Vertical).unwrap_or_else(|| {
                    event.amount_v120(Axis::Vertical).unwrap_or(0.0) * 15.0 / 120.
                });
                let horizontal_v120 = event.amount_v120(Axis::Horizontal);
                let vertical_v120 = event.amount_v120(Axis::Vertical);

                let mut frame = AxisFrame::new(event.time_msec()).source(source);
                if horizontal_amount != 0.0 {
                    frame = frame.value(Axis::Horizontal, horizontal_amount);
                    if let Some(v) = horizontal_v120 {
                        frame = frame.v120(Axis::Horizontal, v as i32);
                    }
                }
                if vertical_amount != 0.0 {
                    frame = frame.value(Axis::Vertical, vertical_amount);
                    if let Some(v) = vertical_v120 {
                        frame = frame.v120(Axis::Vertical, v as i32);
                    }
                }
                if source == AxisSource::Finger {
                    if event.amount(Axis::Horizontal) == Some(0.0) {
                        frame = frame.stop(Axis::Horizontal);
                    }
                    if event.amount(Axis::Vertical) == Some(0.0) {
                        frame = frame.stop(Axis::Vertical);
                    }
                }

                let pointer = self.seat.get_pointer().unwrap();
                pointer.axis(self, frame);
                pointer.frame(self);
            }
            InputEvent::TouchDown { event } => {
                let Some(rect) = self.output_rect() else {
                    return;
                };
                let mut location = event.position_transformed(rect.size) + rect.loc.to_f64();
                self.clamp_pointer(&mut location);

                // 触摸即聚焦：抬起命中窗口并把键盘焦点交给它，客户端 text-input
                // 重新获得焦点后 IME 才会跟随（触摸设备常无物理键盘）。
                let hit = self.space.element_under(location).map(|(w, _)| w.clone());
                if let Some(window) = hit {
                    self.space.raise_element(&window, true);
                    if let Some(toplevel) = window.toplevel() {
                        let serial = SERIAL_COUNTER.next_serial();
                        self.seat.get_keyboard().unwrap().set_focus(
                            self,
                            Some(toplevel.wl_surface().clone()),
                            serial,
                        );
                    }
                }

                let serial = SERIAL_COUNTER.next_serial();
                let focus = self.surface_under(location);
                self.seat.get_touch().unwrap().down(
                    self,
                    focus,
                    &TouchDown {
                        slot: event.slot(),
                        location,
                        serial,
                        time: event.time_msec(),
                    },
                );
            }
            InputEvent::TouchMotion { event } => {
                let Some(rect) = self.output_rect() else {
                    return;
                };
                let mut location = event.position_transformed(rect.size) + rect.loc.to_f64();
                self.clamp_pointer(&mut location);

                // 焦点只在 down 时确定；motion 传入的位置仅用于拖放命中判定。
                let focus = self.surface_under(location);
                self.seat.get_touch().unwrap().motion(
                    self,
                    focus,
                    &TouchMove {
                        slot: event.slot(),
                        location,
                        time: event.time_msec(),
                    },
                );
            }
            InputEvent::TouchUp { event } => {
                let serial = SERIAL_COUNTER.next_serial();
                self.seat.get_touch().unwrap().up(
                    self,
                    &TouchUp {
                        slot: event.slot(),
                        serial,
                        time: event.time_msec(),
                    },
                );
            }
            InputEvent::TouchCancel { .. } => {
                self.seat.get_touch().unwrap().cancel(self);
            }
            InputEvent::TouchFrame { .. } => {
                self.seat.get_touch().unwrap().frame(self);
            }
            _ => {}
        }
    }

    /// 注入一个按键（屏幕键盘 → `archoera_shell_v1.key`）。
    ///
    /// 走与物理键盘完全相同的路径（座位键盘 + 输入法键盘抓取）：fcitx5 等 IME
    /// 能正常处理后，未被消费的按键再由 IME 经虚拟键盘转发给焦点客户端。
    /// `evdev` 为 evdev 键码（KEY_*），内部换算为 XKB keycode（+8）。
    pub fn inject_key(&mut self, evdev: u32, pressed: bool) {
        const EVDEV_OFFSET: u32 = 8;
        let keycode = Keycode::new(evdev.saturating_add(EVDEV_OFFSET));
        let key_state = if pressed {
            KeyState::Pressed
        } else {
            KeyState::Released
        };
        let serial = SERIAL_COUNTER.next_serial();
        let time = crate::state::monotonic_now().as_millis() as u32;
        self.seat.get_keyboard().unwrap().input::<(), _>(
            self,
            keycode,
            key_state,
            serial,
            time,
            |_, _, _| FilterResult::Forward,
        );
    }

    /// 把指针位置夹取到输出范围内。
    fn clamp_pointer(&self, location: &mut Point<f64, Logical>) {
        let Some(rect) = self.output_rect() else {
            return;
        };
        let max_x = (rect.loc.x + rect.size.w - 1) as f64;
        let max_y = (rect.loc.y + rect.size.h - 1) as f64;
        location.x = location
            .x
            .clamp(rect.loc.x as f64, max_x.max(rect.loc.x as f64));
        location.y = location
            .y
            .clamp(rect.loc.y as f64, max_y.max(rect.loc.y as f64));
    }
}

/// 把 XKB keycode（evdev + 8）映射为媒体键。
fn media_key_for(keycode: Keycode) -> Option<MediaKey> {
    const EVDEV_OFFSET: u32 = 8;
    let evdev = keycode.raw().saturating_sub(EVDEV_OFFSET);
    Some(match evdev {
        114 => MediaKey::VolumeDown, // KEY_VOLUMEDOWN
        115 => MediaKey::VolumeUp,   // KEY_VOLUMEUP
        113 => MediaKey::Mute,       // KEY_MUTE
        164 => MediaKey::PlayPause,  // KEY_PLAYPAUSE
        163 => MediaKey::Next,       // KEY_NEXTSONG
        165 => MediaKey::Previous,   // KEY_PREVIOUSSONG
        166 => MediaKey::Stop,       // KEY_STOPCD
        _ => return None,
    })
}

/// 把 XKB keycode（evdev + 8）映射为电源/睡眠键。
fn power_key_for(keycode: Keycode) -> Option<PowerKey> {
    const EVDEV_OFFSET: u32 = 8;
    let evdev = keycode.raw().saturating_sub(EVDEV_OFFSET);
    Some(match evdev {
        116 => PowerKey::Power,   // KEY_POWER
        142 => PowerKey::Sleep,   // KEY_SLEEP
        205 => PowerKey::Suspend, // KEY_SUSPEND
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_evdev_media_keys_via_xkb_offset() {
        for (evdev, expected) in [
            (114u32, MediaKey::VolumeDown),
            (115, MediaKey::VolumeUp),
            (113, MediaKey::Mute),
            (164, MediaKey::PlayPause),
            (163, MediaKey::Next),
            (165, MediaKey::Previous),
            (166, MediaKey::Stop),
        ] {
            assert_eq!(media_key_for(Keycode::new(evdev + 8)), Some(expected));
        }
    }

    #[test]
    fn ordinary_keys_are_not_media_keys() {
        assert_eq!(media_key_for(Keycode::new(30 + 8)), None); // KEY_A
        assert_eq!(media_key_for(Keycode::new(8)), None); // evdev 0
    }

    #[test]
    fn maps_evdev_power_keys_via_xkb_offset() {
        for (evdev, expected) in [
            (116u32, PowerKey::Power),
            (142, PowerKey::Sleep),
            (205, PowerKey::Suspend),
        ] {
            assert_eq!(power_key_for(Keycode::new(evdev + 8)), Some(expected));
        }
        assert_eq!(power_key_for(Keycode::new(30 + 8)), None); // KEY_A
    }
}
