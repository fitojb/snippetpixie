/*
* Copyright (c) 2018 Byte Pixie Limited (https://www.bytepixie.com)
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU General Public
* License as published by the Free Software Foundation; either
* version 2 of the License, or (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
* General Public License for more details.
*
* You should have received a copy of the GNU General Public
* License along with this program; if not, write to the
* Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
* Boston, MA 02110-1301 USA
*
*/

namespace SnippetPixie {
    public class Application : Gtk.Application {
        public const string ID = "com.github.bytepixie.snippetpixie";
        public const string VERSION = "1.3.3";

        private const ulong SLEEP_INTERVAL = (ulong) TimeSpan.MILLISECOND * 10;
        private const ulong SLEEP_INTERVAL_RETRY = SLEEP_INTERVAL * 2;
        private const ulong SLEEP_INTERVAL_LONG = SLEEP_INTERVAL * 20;

        private const string placeholder_delimiter = "$$";
        private const string placeholder_macro = "@";
        private const string placeholder_delimiter_escaped = "$\\$";

        private static Application? _app = null;
        private static bool app_running = false;

        private bool show = true;
        private bool snap = false;
        public MainWindow app_window { get; private set; }

        // For tracking keystrokes.
        private Atspi.DeviceListenerCB listener_cb;
        private Atspi.DeviceListener listener;
        private Atspi.KeyListenerSyncType listener_sync_type = Atspi.KeyListenerSyncType.ALL_WINDOWS;
        private static bool registered_listeners = false;
        private static bool listening = false;
        private Gtk.Clipboard selection;
        private Gtk.Clipboard clipboard;
        private Thread check_thread;
        private static bool checking = false;

        // For tracking active window.
        private Wnck.Screen wnck_screen;
        private Wnck.Window wnck_win;
        private Wnck.Application wnck_app;

        // For tracking last/current focused editable text control per application.
        private Atspi.EventListenerCB focused_event_listener_cb;
        private Gee.HashMap<int,Atspi.EditableText> focused_controls;

        // Unsupported applications, i.e. should not expand in, or currently can't.
        private Gee.ArrayList<string> blacklist;

        // Troublesome applications that should only be expanded in if they decide to play nice and emit events.
        private Gee.ArrayList<string> greylist;

        // Clipboard data for save/restore.
        private string clipboard_text;
        private Gdk.Pixbuf? clipboard_image;

        public SnippetsManager snippets_manager;

        public Application () {
            Object (
                application_id: ID,
                flags: ApplicationFlags.HANDLES_COMMAND_LINE
            );
        }

        protected override void shutdown () {
            debug ("shutdown");
            base.shutdown ();
            cleanup ();
        }

        protected override void activate () {
            if (snippets_manager == null) {
                snippets_manager = new SnippetsManager ();
            }

            if (show) {
                build_ui ();
            }

            // We only want the one listener process.
            lock (app_running) {
                if (app_running) {
                    return;
                }

                app_running = true;
            }

            // Set up AT-SPI listeners.
            Atspi.init();

            if (Atspi.is_initialized () == false) {
                message ("AT-SPI not initialized.");
                quit ();
            }

            // Map of last focused editable text control with its application's PID.
            focused_controls = new Gee.HashMap<int,Atspi.EditableText> ();

            // TODO: Expose as option and save in settings.
            blacklist = new Gee.ArrayList<string> ();
            blacklist.add (this.application_id); // Reason: Do not want to expand snippets within app, gets messy!
            blacklist.add ("io.elementary.terminal"); // Reason: Terminals not supported at present.
            blacklist.add ("Alacritty"); // Reason: Terminals not supported at present.
            blacklist.add ("konsole"); // Reason: Terminals not supported at present.
            blacklist.add ("stterm"); // Reason: Terminals not supported at present.
            blacklist.add ("Terminal"); // Reason: Terminals not supported at present.
            blacklist.add ("terminator"); // Reason: Terminals not supported at present.
            blacklist.add ("urxvt"); // Reason: Terminals not supported at present.
            blacklist.add ("xterm"); // Reason: Terminals not supported at present.

            // TODO: Expose as option and save in settings.
            greylist = new Gee.ArrayList<string> ();
            greylist.add ("Firefox"); // Reason: Inputs loose focus on every keystroke.

            listener_cb = (Atspi.DeviceListenerCB) on_key_released_event;
            listener = new Atspi.DeviceListener ((owned) listener_cb);

            selection = Gtk.Clipboard.get (Gdk.SELECTION_PRIMARY);
            clipboard = Gtk.Clipboard.get (Gdk.SELECTION_CLIPBOARD);

            wnck_screen = Wnck.Screen.get_default ();

            if (wnck_screen != null) {
                //
                // Don't want expansion within Snippet Pixie, and also need to ensure non-accessible windows behave better.
                //
                wnck_screen.active_window_changed.connect (() => {
                    wnck_win = wnck_screen.get_active_window ();
                    debug ("Active window changed.");

                    if (wnck_win != null) {
                        wnck_app = wnck_win.get_application ();
                        debug ("Current app '%s'.", wnck_app.get_name () );

                        if (wnck_app != null) {
                            // TODO: Use wildcard match, e.g. konsole prepends running command on name by default.
                            if (blacklist.size > 0 && blacklist.contains (wnck_app.get_name ())) {
                                debug ("Nope, not expanding snippets within %s!", wnck_app.get_name ());
                                deregister_listeners ();
                            } else if (greylist.size > 0 && greylist.contains (wnck_app.get_name ())) {
                                debug ("Might not be expanding snippets within %s, we'll see.", wnck_app.get_name ());
                                if (listener_sync_type != Atspi.KeyListenerSyncType.NOSYNC) {
                                    deregister_listeners ();
                                }
                                listener_sync_type = Atspi.KeyListenerSyncType.NOSYNC;
                                register_listeners ();
                            } else if (focused_controls.has_key (wnck_app.get_pid ())) {
                                debug ("Looks like we're returning to %s and previously had an editable text ctrl focused.", wnck_app.get_name ());
                                if (listener_sync_type != Atspi.KeyListenerSyncType.NOSYNC) {
                                    deregister_listeners ();
                                }
                                listener_sync_type = Atspi.KeyListenerSyncType.NOSYNC;
                                register_listeners ();
                            } else {
                                if (listener_sync_type != Atspi.KeyListenerSyncType.ALL_WINDOWS) {
                                    deregister_listeners ();
                                }
                                listener_sync_type = Atspi.KeyListenerSyncType.ALL_WINDOWS;
                                register_listeners ();
                            }
                        }
                    }
                });

                // Cleanup any data associated with just closed application.
                wnck_screen.application_closed.connect ((app) => {
                    if (focused_controls.has_key (app.get_pid ())) {
                        focused_controls.unset (app.get_pid ());
                    }
                });
            } else {
                debug ("Could not get default screen object for monitoring windows, bailing.");
                quit ();
            }
        }

        private void cleanup() {
            debug ("cleanup");

            lock (app_running) {
                if (app_running) {
                    deregister_listeners ();

                    var atspi_exit_code = Atspi.exit();
                    debug ("AT-SPI exit code is %d.", atspi_exit_code);
                } // app_running
            }
        }

        private void register_listeners () {
            if (registered_listeners == false) {
                lock (registered_listeners) {

                    debug ("Registering listeners...");

                    try {
                        // Single keystrokes.
                        Atspi.register_keystroke_listener (listener, null, 0, Atspi.EventType.KEY_RELEASED_EVENT, listener_sync_type | Atspi.KeyListenerSyncType.NOSYNC);

                        // Shift.
                        Atspi.register_keystroke_listener (listener, null, IBus.ModifierType.SHIFT_MASK, Atspi.EventType.KEY_RELEASED_EVENT, listener_sync_type | Atspi.KeyListenerSyncType.NOSYNC);
                        // Shift-Lock.
                        Atspi.register_keystroke_listener (listener, null, IBus.ModifierType.LOCK_MASK, Atspi.EventType.KEY_RELEASED_EVENT, listener_sync_type | Atspi.KeyListenerSyncType.NOSYNC);
                        // Shift + Shift-Lock.
                        Atspi.register_keystroke_listener (listener, null, IBus.ModifierType.SHIFT_MASK | IBus.ModifierType.LOCK_MASK, Atspi.EventType.KEY_RELEASED_EVENT, listener_sync_type | Atspi.KeyListenerSyncType.NOSYNC);

                        // Mod2 (NumLock).
                        Atspi.register_keystroke_listener (listener, null, IBus.ModifierType.MOD2_MASK, Atspi.EventType.KEY_RELEASED_EVENT, listener_sync_type | Atspi.KeyListenerSyncType.NOSYNC);
                        // Mod2 + Shift.
                        Atspi.register_keystroke_listener (listener, null, IBus.ModifierType.MOD2_MASK | IBus.ModifierType.SHIFT_MASK, Atspi.EventType.KEY_RELEASED_EVENT, listener_sync_type | Atspi.KeyListenerSyncType.NOSYNC);
                        // Mod2 + Shift-Lock.
                        Atspi.register_keystroke_listener (listener, null, IBus.ModifierType.MOD2_MASK | IBus.ModifierType.LOCK_MASK, Atspi.EventType.KEY_RELEASED_EVENT, listener_sync_type | Atspi.KeyListenerSyncType.NOSYNC);
                        // Mod2 + Shift + Shift-Lock.
                        Atspi.register_keystroke_listener (listener, null, IBus.ModifierType.MOD2_MASK | IBus.ModifierType.SHIFT_MASK | IBus.ModifierType.LOCK_MASK, Atspi.EventType.KEY_RELEASED_EVENT, listener_sync_type | Atspi.KeyListenerSyncType.NOSYNC);

                        // Mod5 (ISO_Level3_Shift/Alt Gr).
                        Atspi.register_keystroke_listener (listener, null, IBus.ModifierType.MOD5_MASK, Atspi.EventType.KEY_RELEASED_EVENT, listener_sync_type | Atspi.KeyListenerSyncType.NOSYNC);
                        // Mod5 + Shift.
                        Atspi.register_keystroke_listener (listener, null, IBus.ModifierType.MOD5_MASK | IBus.ModifierType.SHIFT_MASK, Atspi.EventType.KEY_RELEASED_EVENT, listener_sync_type | Atspi.KeyListenerSyncType.NOSYNC);
                        // Mod5 + Shift-Lock.
                        Atspi.register_keystroke_listener (listener, null, IBus.ModifierType.MOD5_MASK | IBus.ModifierType.LOCK_MASK, Atspi.EventType.KEY_RELEASED_EVENT, listener_sync_type | Atspi.KeyListenerSyncType.NOSYNC);
                        // Mod5 + Shift + Shift-Lock.
                        Atspi.register_keystroke_listener (listener, null, IBus.ModifierType.MOD5_MASK | IBus.ModifierType.SHIFT_MASK | IBus.ModifierType.LOCK_MASK, Atspi.EventType.KEY_RELEASED_EVENT, listener_sync_type | Atspi.KeyListenerSyncType.NOSYNC);
                    } catch (Error e) {
                        message ("Could not register keystroke listener: %s", e.message);
                        Atspi.exit ();
                        quit ();
                    }

                    try {
                        focused_event_listener_cb = (Atspi.EventListenerCB) on_focus;
                        Atspi.EventListener.register_from_callback ((owned) focused_event_listener_cb, "focus:");
                    } catch (Error e) {
                        message ("Could not register focus event listener: %s", e.message);
                        Atspi.exit ();
                        quit ();
                    }

                    registered_listeners = true;
                    start_listening ();
                } // lock registered_listeners
            } // registered_listeners false
        }

        private void deregister_listeners () {
            stop_listening ();

            if (registered_listeners == true) {
                lock (registered_listeners) {
                    registered_listeners = false;

                    debug ("De-registering listeners...");

                    try {
                        // Single keystrokes.
                        Atspi.deregister_keystroke_listener (listener, null, 0, Atspi.EventType.KEY_RELEASED_EVENT);

                        // Shift.
                        Atspi.deregister_keystroke_listener (listener, null, IBus.ModifierType.SHIFT_MASK, Atspi.EventType.KEY_RELEASED_EVENT);
                        // Shift-Lock.
                        Atspi.deregister_keystroke_listener (listener, null, IBus.ModifierType.LOCK_MASK, Atspi.EventType.KEY_RELEASED_EVENT);
                        // Shift + Shift-Lock.
                        Atspi.deregister_keystroke_listener (listener, null, IBus.ModifierType.SHIFT_MASK | IBus.ModifierType.LOCK_MASK, Atspi.EventType.KEY_RELEASED_EVENT);

                        // Mod2 (NumLock).
                        Atspi.deregister_keystroke_listener (listener, null, IBus.ModifierType.MOD2_MASK, Atspi.EventType.KEY_RELEASED_EVENT);
                        // Mod2 + Shift.
                        Atspi.deregister_keystroke_listener (listener, null, IBus.ModifierType.MOD2_MASK | IBus.ModifierType.SHIFT_MASK, Atspi.EventType.KEY_RELEASED_EVENT);
                        // Mod2 + Shift-Lock.
                        Atspi.deregister_keystroke_listener (listener, null, IBus.ModifierType.MOD2_MASK | IBus.ModifierType.LOCK_MASK, Atspi.EventType.KEY_RELEASED_EVENT);
                        // Mod2 + Shift + Shift-Lock.
                        Atspi.deregister_keystroke_listener (listener, null, IBus.ModifierType.MOD2_MASK | IBus.ModifierType.SHIFT_MASK | IBus.ModifierType.LOCK_MASK, Atspi.EventType.KEY_RELEASED_EVENT);

                        // Mod5 (ISO_Level3_Shift/Alt Gr).
                        Atspi.deregister_keystroke_listener (listener, null, IBus.ModifierType.MOD5_MASK, Atspi.EventType.KEY_RELEASED_EVENT);
                        // Mod5 + Shift.
                        Atspi.deregister_keystroke_listener (listener, null, IBus.ModifierType.MOD5_MASK | IBus.ModifierType.SHIFT_MASK, Atspi.EventType.KEY_RELEASED_EVENT);
                        // Mod5 + Shift-Lock.
                        Atspi.deregister_keystroke_listener (listener, null, IBus.ModifierType.MOD5_MASK | IBus.ModifierType.LOCK_MASK, Atspi.EventType.KEY_RELEASED_EVENT);
                        // Mod5 + Shift + Shift-Lock.
                        Atspi.deregister_keystroke_listener (listener, null, IBus.ModifierType.MOD5_MASK | IBus.ModifierType.SHIFT_MASK | IBus.ModifierType.LOCK_MASK, Atspi.EventType.KEY_RELEASED_EVENT);
                    } catch (Error e) {
                        message ("Could not deregister keystroke listener: %s", e.message);
                        Atspi.exit ();
                        quit ();
                    }

                    try {
                        Atspi.EventListener.deregister_from_callback ((owned) focused_event_listener_cb, "focus:");
                    } catch (Error e) {
                        message ("Could not deregister focus event listener: %s", e.message);
                        Atspi.exit ();
                        quit ();
                    }
                } // lock registered_listeners
            } // registered_listeners true
        }

        private void start_listening () {
            lock (listening) {
                listening = true;
            }
            debug ("Started listening.");
        }

        private void stop_listening () {
            lock (listening) {
                listening = false;
            }
            debug ("Stopped listening.");
        }

        [CCode (instance_pos = -1)]
        private bool on_focus (Atspi.Event event) {
            try {
                var app = event.source.get_application ();
                debug ("!!! FOCUS EVENT Type ='%s', Source: '%s'", event.type, app.get_name ());

                if (app.get_name () == this.application_id) {
                    debug ("Nope, not monitoring within %s!", app.get_name ());
                } else {
                    // Whether we can get current control or not, cleanup last known control.
                    if (focused_controls.has_key (wnck_app.get_pid ())) {
                        focused_controls.unset (wnck_app.get_pid ());
                    }

                    // Try and grab editable control's handle.
                    var focused_control = event.source.get_editable_text_iface ();

                    if (focused_control != null) {
                        debug ("Focused editable text control found.");
                        focused_controls.set (wnck_app.get_pid (), focused_control);

                        if (listener_sync_type != Atspi.KeyListenerSyncType.NOSYNC) {
                            deregister_listeners ();
                        }
                        listener_sync_type = Atspi.KeyListenerSyncType.NOSYNC;
                        register_listeners ();
                    }
                }
            } catch (Error e) {
                message ("Could not get focused control: %s", e.message);
                return false;
            }

            return false;
        }

        [CCode (instance_pos = -1)]
        private bool on_key_released_event (Atspi.DeviceEvent stroke) {
            // Belts and braces check to make sure we stop handling events while checking for potential abbreviation.
            if (listening == false || checking == true) {
                return false;
            }

            debug ("*** KEY EVENT ID = '%u', Str = '%s'", stroke.id, stroke.event_string);

            if (
                checking != true &&
                stroke.is_text &&
                stroke.event_string != null &&
                snippets_manager.triggers != null &&
                snippets_manager.triggers.size > 0 &&
                snippets_manager.triggers.has_key (stroke.event_string)
                ) {
                debug ("!!! GOT A TRIGGER KEY MATCH !!!");

                if (focused_controls.has_key (wnck_app.get_pid ()) && listener_sync_type == Atspi.KeyListenerSyncType.NOSYNC) {
                    // Let thread check for abbreviation, while we let the target window have its keystroke.
                    check_thread = new Thread<bool> ("check_thread", editable_text_check);
                } else {
                    // Let thread check for abbreviation, while we let the target window have its keystroke.
                    check_thread = new Thread<bool> ("check_thread", text_selection_check);
                }
            } // if something to check

            return false;
        }

        private bool text_selection_check () {
            var expanded = false;

            if (checking != true) {
                lock (checking) {
                    checking = true;
                    debug ("Checking for abbreviation via text selection...");

                    stop_listening ();
                    release_keys ();
                    selection.clear ();

                    var last_str = "";
                    var tries = 1;
                    var min = 1;
                    var last_min = min;
                    var max = snippets_manager.max_abbr_len;

                    for (int pos = 1; pos <= max; pos++) {
                        var grow_count = 1;

                        if (pos < min) {
                            grow_count = min - pos + 1;
                            pos = min;
                            debug ("New grow count: %d", grow_count);
                        }

                        grow_selection (grow_count, tries);

                        Thread.yield ();
                        Thread.usleep (SLEEP_INTERVAL * tries);

                        if (selection.wait_is_text_available () == false) {
                            debug ("Waiting a little longer for selection contents...");
                            Thread.yield ();
                            Thread.usleep (SLEEP_INTERVAL_RETRY * tries);
                        }

                        var str = selection.wait_for_text ();
                        debug ("Pos %d, Str '%s'", pos, str);

                        if (str == null || str == last_str || str.char_count () != pos) {
                            tries++;

                            if (tries > 10) {
                                debug ("Tried 10 times to get some text, giving up.");
                                last_str = str; // Forces cancel to unset selection.
                                break;
                            }

                            debug ("Text different than expected, starting again, attempt #%d.", tries);
                            cancel_selection (str);

                            last_str = "";
                            min = last_min;
                            pos = 0;
                            continue;
                        }

                        last_str = str;
                        last_min = min;

                        var count = snippets_manager.count_snippets_ending_with (str);
                        debug ("Count of abbreviations ending with '%s': %d", str, count);

                        if (count < 1) {
                            debug ("Nothing matched '%s'", str);
                            break;
                        } else if (snippets_manager.abbreviations.has_key (str)) {
                            debug ("IT'S AN ABBREVIATION!!!");

                            var body = snippets_manager.abbreviations.get (str);

                            // Before trying to insert the snippet's body, parse it to expand placeholders such as date/time and embedded snippets.
                            var new_offset = -1;
                            var dt = new DateTime.now_local ();
                            body = expand_snippet (body, ref new_offset, dt);
                            body = collapse_escaped_placeholder_delimiter (body, ref new_offset);

                            // Save current clipboard before we use it.
                            save_clipboard ();

                            // Paste the text over the selected abbreviation text.
                            debug ("Setting clipboard with abbreviation body.");
                            clipboard.set_text (body, -1);

                            // Wait until clipboard definitely has the expected contents before pasting.
                            Thread.yield ();
                            Thread.usleep (SLEEP_INTERVAL);

                            if (clipboard.wait_is_text_available () == false) {
                                debug ("Waiting a little longer for clipboard contents to be set...");
                                Thread.yield ();
                                Thread.usleep (SLEEP_INTERVAL_RETRY);
                            }

                            var clip_str = clipboard.wait_for_text ();
                            debug ("Clipboard set to:- '%s'", clip_str);

                            if (clip_str != body) {
                                debug ("Clipboard contents not set to abbreviation body, having another go...");
                                clipboard.set_text (body, -1);
                                Thread.yield ();
                                Thread.usleep (SLEEP_INTERVAL_RETRY);
                            }

                            debug ("Pasting clipboard.");
                            paste ();

                            expanded = true;
                            break;
                        } // have matching abbreviation

                        // We can can try and speed things up a bit by not waiting for async selection clipboard on every character.
                        min = snippets_manager.min_length_ending_with (str);
                        debug ("Minimum length of abbreviations ending with '%s': %d", str, min);
                        max = snippets_manager.max_length_ending_with (str);
                        debug ("Maximum length of abbreviations ending with '%s': %d", str, max);
                    } // step back through characters

                    if (expanded == true) {
                        // Restore clipboard from data saved before we used it.
                        restore_clipboard ();
                    } else {
                        cancel_selection (last_str);
                    }

                    checking = false;
                    start_listening ();
                } // lock checking
            } // not checking

            return expanded;
        }

        private void save_clipboard () {
            if (clipboard.wait_is_text_available ()) {
                clipboard_text = clipboard.wait_for_text ();
            } else {
                clipboard_text = null;
            }

            if (clipboard.wait_is_image_available ()) {
                clipboard_image = clipboard.wait_for_image ();
            } else {
                clipboard_image = null;
            }
        }

        private void restore_clipboard () {
            debug ("Restoring clipboard...");

            if (clipboard_text == null && clipboard_image == null) {
                debug ("No clipboard saved, not restoring clipboard.");
                return;
            }

            Thread.yield ();
            Thread.usleep (SLEEP_INTERVAL);

            var selection_clear = false;
            for (int tries = 0; tries < 3; tries++) {
                if (selection.wait_is_text_available () == true) {
                    // Paste not happened?
                    debug ("Waiting a little longer before trying clipboard restore...");
                    Thread.yield ();
                    Thread.usleep (SLEEP_INTERVAL_RETRY);
                } else {
                    selection_clear = true;
                    break;
                }
            }

            if (selection_clear == false) {
                debug ("Selection hasn't cleared, not restoring clipboard.");
                return;
            }

            if (clipboard_text != null) {
                clipboard.set_text (clipboard_text, -1);
            }

            if (clipboard_image != null) {
                clipboard.set_image (clipboard_image);
            }

            clipboard.store ();
            debug ("Restored clipboard.");
        }

        private bool editable_text_check () {
            var expanded = false;

            if (checking != true) {
                lock (checking) {
                    checking = true;
                    debug ("Checking for abbreviation via editable text...");

                    stop_listening ();

                    if (focused_controls.has_key (wnck_app.get_pid ()) == false) {
                        debug ("Focused control missing from app map, oops!");
                        checking = false;
                        start_listening ();
                        return expanded;
                    }

                    var ctrl = (Atspi.Text) focused_controls.get (wnck_app.get_pid ());
                    var caret_offset = 0;

                    Thread.yield ();
                    Thread.usleep (SLEEP_INTERVAL);

                    try {
                        caret_offset = ctrl.get_caret_offset ();
                    } catch (Error e) {
                        message ("Could not get caret offset: %s", e.message);
                        checking = false;
                        start_listening ();
                        return expanded;
                    }
                    debug ("Caret Offset %d", caret_offset);

                    var last_str = "";
                    var tries = 1;
                    var min = 1;
                    var last_min = 1;

                    for (int pos = 1; pos <= snippets_manager.max_abbr_len; pos++) {
                        if (pos < min) {
                            continue;
                        }

                        var sel_start = caret_offset - pos;
                        var sel_end = caret_offset;
                        var str = "";

                        try {
                            str = ctrl.get_text (sel_start, sel_end);
                        } catch (Error e) {
                            message ("Could not get text between positions %d and %d: %s", sel_start, sel_end, e.message);
                            break;
                        }
                        debug ("Pos %d, Str %s", pos, str);

                        if (str == null || str == last_str || str.char_count () != pos) {
                            tries++;

                            if (tries > 3) {
                                debug ("Tried 3 times to get some text, giving up.");
                                break;
                            }

                            debug ("Text different than expected, starting again, attempt #%d.", tries);
                            last_str = "";
                            min = last_min;
                            pos = 0;
                            continue;
                        }

                        last_str = str;
                        last_min = min;

                        var count = snippets_manager.count_snippets_ending_with (str);
                        debug ("Count of abbreviations ending with '%s': %d", str, count);

                        if (count < 1) {
                            debug ("Nothing matched '%s'", str);
                            break;
                        } else if (snippets_manager.abbreviations.has_key (str)) {
                            debug ("IT'S AN ABBREVIATION!!!");

                            var focused_control = (Atspi.EditableText) focused_controls.get (wnck_app.get_pid ());

                            try {
                                if (! focused_control.delete_text (sel_start, sel_end)) {
                                    message ("Could not delete abbreviation string from text.");
                                    break;
                                }
                            } catch (Error e) {
                                message ("Could not delete abbreviation string from text between positions %d and %d: %s", sel_start, sel_end, e.message);
                                break;
                            }

                            var body = snippets_manager.abbreviations.get (str);

                            // Before trying to insert the snippet's body, parse it to expand placeholders such as date/time and embedded snippets.
                            var new_offset = -1;
                            var dt = new DateTime.now_local ();
                            body = expand_snippet (body, ref new_offset, dt);
                            body = collapse_escaped_placeholder_delimiter (body, ref new_offset);

                            try {
                                if (! focused_control.insert_text (sel_start, body, body.length)) {
                                    message ("Could not insert expanded snippet into text.");
                                    break;
                                }
                            } catch (Error e) {
                                message ("Could not insert expanded snippet into text at position %d: %s", sel_start, e.message);
                                break;
                            }

                            if (new_offset >= 0) {
                                try {
                                    if (! ((Atspi.Text) focused_control).set_caret_offset (sel_start + new_offset)) {
                                        message ("Could not set new cursor position.");
                                        break;
                                    }
                                } catch (Error e) {
                                    message ("Could not set new cursor at position %d: %s", sel_start + new_offset, e.message);
                                    break;
                                }
                            }

                            expanded = true;
                            break;
                        } // have matching abbreviation

                        // We can can try and speed things up a bit.
                        min = snippets_manager.min_length_ending_with (str);
                        debug ("Minimum length of abbreviations ending with '%s': %d", str, min);
                    } // step back through characters

                    checking = false;
                    start_listening ();
                } // lock checking
            } // not checking

            return expanded;
        }

        private string collapse_escaped_placeholder_delimiter (owned string body, ref int caret_offset) {
            var diff = placeholder_delimiter_escaped.length - placeholder_delimiter.length;
            var index = body.index_of (placeholder_delimiter_escaped);

            while (index >= 0) {
                body = body.splice (index, index + placeholder_delimiter_escaped.length, placeholder_delimiter);

                if (caret_offset > index) {
                    caret_offset -= diff;
                }

                index = body.index_of (placeholder_delimiter_escaped);
            }

            return body;
        }

        private string expand_snippet (string body, ref int caret_offset, DateTime dt, int level = 0) {
            level++;

            // We don't want keep on going down the rabbit hole for ever.
            if (level > 3) {
                debug ("Too much inception at level %d, returning to the surface.", level);
                return body;
            }

            // Quick check that placeholder exists at least once in string, and a macro name start is too.
            if (body.contains (placeholder_delimiter) && body.contains (placeholder_delimiter.concat (placeholder_macro))) {
                string result = "";
                var bits = body.split (placeholder_delimiter);

                foreach (string bit in bits) {
                    // Other Placeholder.
                    bit = expand_snippet_placeholder (bit, ref caret_offset, dt, level, result);

                    // Date/Time Placeholder.
                    bit = expand_date_placeholder (bit, dt);

                    // Clipboard Placeholder.
                    bit = expand_clipboard_placeholder (bit);

                    // Cursor Placeholder.
                    if (expand_cursor_placeholder (bit)) {
                        caret_offset = result.length;
                        debug ("New caret offset = %d", caret_offset);
                    } else {
                        result = result.concat (bit);
                    }
                }

                return result;
            }

            return body;
        }

        private string expand_snippet_placeholder (owned string body, ref int caret_offset, DateTime dt, int level, string result) {
            string macros[] = { "snippet", _("snippet") };
            Gee.HashMap<string,bool> done = new Gee.HashMap<string,bool> ();

            foreach (string macro in macros) {
                // If macro name not translated, don't repeat ourselves.
                if (done.has_key (macro)) {
                    continue;
                } else {
                    done.set (macro, true);
                }

                /*
                 * Expect "@snippet:abbr"
                 */
                if (body.index_of (placeholder_macro.concat (macro, ":")) == 0) {
                    var str = body.substring (placeholder_macro.concat (macro, ":").length);
                    debug ("Embedded snippet placeholder value: '%s'", str);

                    /*
                     * If abbreviation exists, get its body and run through expansion.
                     */
                    if (snippets_manager.abbreviations.has_key (str)) {
                        debug ("Embedded snippet '%s' exists, yay.", str);
                        body = snippets_manager.abbreviations.get (str);

                        var new_offset = -1;
                        body = expand_snippet(body, ref new_offset, dt, level);

                        if (new_offset >= 0) {
                            caret_offset = result.length + new_offset;
                        }

                        // Don't need to process other macro name variants.
                        return body;
                    }
                }
            }

            return body;
        }

        private string expand_date_placeholder (owned string body, DateTime dt) {
            string macros[] = { "date", "time", _("date"), _("time") };
            Gee.HashMap<string,bool> done = new Gee.HashMap<string,bool> ();

            foreach (string macro in macros) {
                // If macro name not translated, don't repeat ourselves.
                if (done.has_key (macro)) {
                    continue;
                } else {
                    done.set (macro, true);
                }

                /*
                 * Test for macro in following order...
                 * @macro@calc:fmt
                 * @macro@calc:
                 * @macro@calc
                 * @macro:fmt
                 * @macro:
                 * @macro
                 */
                if (body.index_of (placeholder_macro.concat (macro, placeholder_macro)) == 0) {
                    var rest = body.substring (placeholder_macro.concat (macro, placeholder_macro).length);

                    var calc = rest.substring (0, rest.index_of (":"));
                    var fmt = rest.substring (calc.length);

                    fmt = maybe_fix_date_placeholder_format (fmt, macro);

                    var ndt = dt.to_local ();
                    var pos = 0;
                    var cnt = 0;
                    var nums = calc.split_set ("YMWDhms");

                    if (nums.length == 0) {
                        warning (_("Date adjustment does not seem to have a positive or negative integer in placeholder '%1$s'."), body);
                        return body;
                    }

                    foreach (string num_str in nums) {
                        cnt++;

                        // Because we expect the calc string to end with a "delimiter", chances are we'll get a blank last element.
                        if (num_str.length == 0 && nums.length == cnt) {
                            continue;
                        }

                        var num = int.parse (num_str);

                        if (num == 0) {
                            warning (_("Date adjustment number %1$d does not seem to start with a positive or negative integer in placeholder '%2$s'."), cnt, body);
                            return body;
                        }

                        pos += num_str.length;
                        var unit = calc.substring (pos, 1);
                        pos++;

                        switch (unit) {
                            case "Y":
                                ndt = ndt.add_years (num);
                                break;
                            case "M":
                                ndt = ndt.add_months (num);
                                break;
                            case "W":
                                ndt = ndt.add_weeks (num);
                                break;
                            case "D":
                                ndt = ndt.add_days (num);
                                break;
                            case "h":
                                ndt = ndt.add_hours (num);
                                break;
                            case "m":
                                ndt = ndt.add_minutes (num);
                                break;
                            case "s":
                                ndt = ndt.add_seconds (num);
                                break;
                            default:
                                warning (_("Date adjustment number %1$d does not seem to end with either 'Y', 'M', 'W', 'D', 'h', 'm' or 's' in placeholder '%2$s'."), cnt, body);
                                return body;
                        }
                    }

                    var result = ndt.format (fmt);

                    if (result == null) {
                        warning (_("Oops, date format '%1$s' could not be parsed."), fmt);
                        return body;
                    } else {
                        return result;
                    }
                } else if (body.index_of (placeholder_macro.concat (macro)) == 0) {
                    var fmt = body.substring (placeholder_macro.concat (macro).length);

                    fmt = maybe_fix_date_placeholder_format (fmt, macro);

                    var result = dt.format (fmt);

                    if (result == null) {
                        warning (_("Oops, date format '%1$s' could not be parsed."), fmt);
                        return body;
                    } else {
                        return result;
                    }
                }
            }

            return body;
        }

        private string maybe_fix_date_placeholder_format (owned string fmt, owned string macro) {
            // Strip leading ":" from format string.
            if (fmt.has_prefix (":")) {
                fmt = fmt.substring (1);
            }

            if (fmt.strip ().length == 0 && (macro == "date" || macro == _("date"))) {
                fmt = "%x";
            }

            if (fmt.strip ().length == 0 && (macro == "time" || macro == _("time"))) {
                fmt = "%X";
            }

            return fmt;
        }

        private string expand_clipboard_placeholder (string body) {
            string macros[] = { "clipboard", _("clipboard") };
            Gee.HashMap<string,bool> done = new Gee.HashMap<string,bool> ();

            foreach (string macro in macros) {
                // If macro name not translated, don't repeat ourselves.
                if (done.has_key (macro)) {
                    continue;
                } else {
                    done.set (macro, true);
                }

                var board = Gtk.Clipboard.get_default (Gdk.Display.get_default ());

                /*
                 * Expect "@clipboard"
                 *
                 * Currently only handles text from clipboard, and this will be the default if other formats added later.
                 */
                if (body.index_of (placeholder_macro.concat (macro)) == 0 && board.wait_is_text_available ()) {
                    var text = board.wait_for_text ();

                    if (text == null) {
                        continue;
                    } else {
                        body = text;
                    }

                    // Don't need to process other macro name variants.
                    return body;
                }
            }

            return body;
        }

        private bool expand_cursor_placeholder (string body) {
            string macros[] = { "cursor", _("cursor") };
            Gee.HashMap<string,bool> done = new Gee.HashMap<string,bool> ();

            foreach (string macro in macros) {
                // If macro name not translated, don't repeat ourselves.
                if (done.has_key (macro)) {
                    continue;
                } else {
                    done.set (macro, true);
                }

                /*
                 * Expect "@cursor"
                 */
                if (body.index_of (placeholder_macro.concat (macro)) == 0) {
                    // Don't need to process other macro name variants.
                    return true;
                }
            }

            return false;
        }

        private void release_keys () {
            debug ("release_keys start");

            perform_key_event ("<Shift_L>", false, 0);
            perform_key_event ("<Shift_R>", false, 0);
            perform_key_event ("<Control_L>", false, 0);
            perform_key_event ("<Control_R>", false, 0);
            perform_key_event ("<Mod1>", false, 0);
            perform_key_event ("<Mod2>", false, 0);
            perform_key_event ("<Mod3>", false, 0);
            perform_key_event ("<Mod4>", false, 0);
            perform_key_event ("<Mod5>", false, 0);

            Thread.yield ();
            Thread.usleep (SLEEP_INTERVAL);

            debug ("release_keys end");
        }

        private void grow_selection (int count, int tries) {
            debug ("grow_selection start");

            for (int num = 0; num < count; num++) {
                perform_key_event ("<Shift>Left", true, 0);
                perform_key_event ("<Shift>Left", false, 0);
            }

            Thread.yield ();
            Thread.usleep (SLEEP_INTERVAL * tries);

            debug ("grow_selection end");
        }

        private void cancel_selection (string? str) {
            debug ("cancel_selection start");

            release_keys ();

            // TODO: In case Clipboard access screwy, more robust check would be to see if any text is selected.
            if (str == null || str.length > 0) {
                perform_key_event ("Right", true, 0);
                perform_key_event ("Right", false, 0);
            }

            selection.clear ();

            Thread.yield ();
            Thread.usleep (SLEEP_INTERVAL);

            debug ("cancel_selection end");
        }

        /**
         * "Borrowed" from Clipped by David Hewitt.
         * https://github.com/davidmhewitt/clipped/blob/b00d44757cc2bf7bc9948d535668099db4ab9896/src/ClipboardManager.vala#L55
         */
        private void paste () {
            debug ("paste start");

            // TODO: Ctrl-v isn't always the right thing to do, e.g. Terminal, or changed paste hot-key combination.
            perform_key_event ("<Control>v", true, 0);
            perform_key_event ("<Control>v", false, 0);

            Thread.yield ();
            Thread.usleep (SLEEP_INTERVAL);

            debug ("paste end");
        }

        /**
         * "Borrowed" from Clipped by David Hewitt.
         * https://github.com/davidmhewitt/clipped/blob/b00d44757cc2bf7bc9948d535668099db4ab9896/src/ClipboardManager.vala#L60
         */
        private static void perform_key_event (string accelerator, bool press, ulong delay) {
            uint keysym;
            Gdk.ModifierType modifiers;
            Gtk.accelerator_parse (accelerator, out keysym, out modifiers);
            unowned X.Display display = Gdk.X11.get_default_xdisplay ();
            int keycode = display.keysym_to_keycode (keysym);

            if (keycode != 0) {
                if (Gdk.ModifierType.CONTROL_MASK in modifiers) {
                    int modcode = display.keysym_to_keycode (Gdk.Key.Control_L);
                    XTest.fake_key_event (display, modcode, press, delay);
                }

                if (Gdk.ModifierType.SHIFT_MASK in modifiers) {
                    int modcode = display.keysym_to_keycode (Gdk.Key.Shift_L);
                    XTest.fake_key_event (display, modcode, press, delay);
                }

                XTest.fake_key_event (display, keycode, press, delay);
            }
        }

        private void build_ui () {
            if (get_windows ().length () > 0) {
                get_windows ().data.present ();
                return;
            }

            var provider = new Gtk.CssProvider ();
            provider.load_from_resource ("com/bytepixie/snippetpixie/Application.css");
            Gtk.StyleContext.add_provider_for_screen (Gdk.Screen.get_default (), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);


            app_window = new MainWindow (this);
            app_window.show_all ();
            add_window (app_window);

            app_window.state_flags_changed.connect (save_ui_settings);
            app_window.delete_event.connect (save_ui_settings_on_delete);

            var quit_action = new SimpleAction ("quit", null);
            add_action (quit_action);
            set_accels_for_action ("app.quit", {"<Control>q"});

            quit_action.activate.connect (() => {
                if (app_window != null) {
                    app_window.destroy ();
                }
            });
        }

        private void save_ui_settings () {
            var settings = new Settings ("com.github.bytepixie.snippetpixie");

            int window_x, window_y;
            app_window.get_position (out window_x, out window_y);
            settings.set_int ("window-x", window_x);
            settings.set_int ("window-y", window_y);

            int window_width, window_height;
            app_window.get_size (out window_width, out window_height);
            settings.set_int ("window-width", window_width);
            settings.set_int ("window-height", window_height);
        }

        private bool save_ui_settings_on_delete () {
            save_ui_settings ();
            return false;
        }

        /**
         * Mostly "Borrowed" from Clipped by David Hewitt.
         * https://github.com/davidmhewitt/clipped/blob/edac68890c2a78357910f05bf44060c2aba5958e/src/Application.vala#L153
         */
        private void update_autostart (bool autostart) {
            var desktop_file_name = application_id + ".desktop";

            if (snap) {
                desktop_file_name = "snippetpixie_snippetpixie.desktop";
            }

            var app_info = new DesktopAppInfo (desktop_file_name);

            if (app_info == null) {
                warning ("Could not find desktop file with name: %s", desktop_file_name);
                return;
            }

            var desktop_file_path = app_info.get_filename();
            var desktop_file = File.new_for_path (desktop_file_path);
            var dest_path = Path.build_path (
                Path.DIR_SEPARATOR_S,
                Environment.get_user_config_dir (),
                "autostart",
                desktop_file_name
            );
            var dest_file = File.new_for_path (dest_path);

            try {
                var parent = dest_file.get_parent ();

                if (! parent.query_exists ()) {
                    parent.make_directory_with_parents ();
                }
                desktop_file.copy (dest_file, FileCopyFlags.OVERWRITE);
            } catch (Error e) {
                warning ("Error making copy of desktop file for autostart: %s", e.message);
                return;
            }

            var keyfile = new KeyFile ();

            try {
                keyfile.load_from_file (dest_path, KeyFileFlags.NONE);

                var exec_string = keyfile.get_string ("Desktop Entry", "Exec");
                var start = exec_string.last_index_of ("snippetpixie");
                var end = start + 12;
                exec_string = exec_string.splice (start, end, "snippetpixie --start");

                keyfile.set_string ("Desktop Entry", "Exec", exec_string);
                keyfile.set_boolean ("Desktop Entry", "X-GNOME-Autostart-enabled", autostart);

                if (keyfile.has_group ("Desktop Action Start")) {
                    keyfile.remove_group ("Desktop Action Start");
                }

                if (keyfile.has_group ("Desktop Action Stop")) {
                    keyfile.remove_group ("Desktop Action Stop");
                }

                keyfile.save_to_file (dest_path);
            } catch (Error e) {
                warning ("Error enabling autostart: %s", e.message);
                return;
            }
        }

        private bool get_autostart () {
            var desktop_file_name = application_id + ".desktop";

            if (snap) {
                desktop_file_name = "snippetpixie_snippetpixie.desktop";
            }

            var dest_path = Path.build_path (
                Path.DIR_SEPARATOR_S,
                Environment.get_user_config_dir (),
                "autostart",
                desktop_file_name
            );

            var dest_file = File.new_for_path (dest_path);

            if (! dest_file.query_exists ()) {
                // By default we want to autostart.
                update_autostart (true);
                return true;
            }

            var autostart = false;
            var keyfile = new KeyFile ();

            try {
                keyfile.load_from_file (dest_path, KeyFileFlags.NONE);
                autostart = keyfile.get_boolean ("Desktop Entry", "X-GNOME-Autostart-enabled");
            } catch (Error e) {
                warning ("Error enabling autostart: %s", e.message);
            }

            return autostart;
        }

        public override int command_line (ApplicationCommandLine command_line) {
            var snap_env = Environment.get_variable ("SNAP");

            if (snap_env != null && snap_env.contains ("snippetpixie")) {
                snap = true;
            }

            show = true;
            bool start = false;
            bool stop = false;
            string autostart = null;
            bool status = false;
            string export_file = null;
            string import_file = null;
            bool force = false;
            bool version = false;
            bool help = false;

            OptionEntry[] options = new OptionEntry[10];
            options[0] = { "show", 0, 0, OptionArg.NONE, ref show, _("Show Snippet Pixie's window (default action)"), null };
            options[1] = { "start", 0, 0, OptionArg.NONE, ref start, _("Start with no window"), null };
            options[2] = { "stop", 0, 0, OptionArg.NONE, ref stop, _("Fully quit the application, including the background process"), null };
            options[3] = { "autostart", 0, 0, OptionArg.STRING, ref autostart, _("Turn auto start of Snippet Pixie on login, on, off, or show status of setting"), "{on|off|status}" };
            options[4] = { "status", 0, 0, OptionArg.NONE, ref status, _("Shows status of the application, exits with status 0 if running, 1 if not"), null };
            options[5] = { "export", 'e', 0, OptionArg.FILENAME, ref export_file, _("Export snippets to file"), "filename" };
            options[6] = { "import", 'i', 0, OptionArg.FILENAME, ref import_file, _("Import snippets from file, skips snippets where abbreviation already exists"), _("filename") };
            options[7] = { "force", 0, 0, OptionArg.NONE, ref force, _("If used in conjunction with import, existing snippets with same abbreviation are updated"), null };
            options[8] = { "version", 0, 0, OptionArg.NONE, ref version, _("Display version number"), null };
            options[9] = { "help", 'h', 0, OptionArg.NONE, ref help, _("Display this help"), null };

            // We have to make an extra copy of the array, since .parse assumes
            // that it can remove strings from the array without freeing them.
            string[] args = command_line.get_arguments ();
            string[] _args = new string[args.length];
            for (int i = 0; i < args.length; i++) {
                _args[i] = args[i];
            }

            OptionContext opt_context;

            try {
                opt_context = new OptionContext ();
                opt_context.set_help_enabled (false);
                opt_context.add_main_entries (options, null);
                unowned string[] tmp = _args;
                opt_context.parse (ref tmp);
            } catch (OptionError e) {
                command_line.print (_("error: %s\n"), e.message);
                command_line.print (_("Run '%s --help' to see a full list of available command line options.\n"), args[0]);
                return 0;
            }

            if (help) {
                command_line.print ("%s\n", opt_context.get_help (true, null));
                return 0;
            }

            if (version) {
                command_line.print ("%s\n", VERSION);
                return 0;
            }

            lock (app_running) {
                if (stop) {
                    command_line.print (_("Quitting…\n"));
                    var app = get_default ();
                    app.quit ();
                    return 0;
                }

                if (status) {
                    if (app_running) {
                        command_line.print (_("Running.\n"));
                        return 0;
                    } else {
                        command_line.print (_("Not Running.\n"));
                        return 1;
                    }
                }

                switch (autostart) {
                    case null:
                        break;
                    case "on":
                        update_autostart (true);
                        return 0;
                    case "off":
                        update_autostart (false);
                        return 0;
                    case "status":
                        if (get_autostart ()) {
                            command_line.print ("on\n");
                        } else {
                            command_line.print ("off\n");
                        }
                        return 0;
                    default:
                        command_line.print (_("Invalid autostart value \"%s\".\n"), autostart);
                        help = true;
                        break;
                }

                if (export_file != null) {
                    if (snippets_manager == null) {
                        snippets_manager = new SnippetsManager ();
                    }

                    return snippets_manager.export_to_file (export_file);
                }

                if (import_file != null) {
                    if (snippets_manager == null) {
                        snippets_manager = new SnippetsManager ();
                    }

                    return snippets_manager.import_from_file (import_file, force);
                }

                if (start) {
                    show = false;
                }

                // If we get here we're either showing the window or running the background process.
                if ( show == false || ! app_running ) {
                    get_autostart ();
                    hold ();
                }
            } // lock app_running

            activate ();

            return 0;
        }

        public static new Application get_default () {
            if (_app == null) {
                _app = new Application ();
            }
            return _app;
        }

        public static int main (string[] args) {
            if (Thread.supported () == false) {
                stderr.printf(_("Cannot run without threads.\n"));
                return -1;
            }

            // Tell X11 we're using threads.
            X.init_threads ();

            var app = get_default ();
            var exit_code = app.run (args);

            debug ("Application terminated with exit code %d.", exit_code);
            return exit_code;
        }
    }
}
