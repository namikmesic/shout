import SwiftUI
import ShoutKit

/// Scribe settings, grouped like the rest of Settings. Shown on the Settings page's Scribe tab and
/// from the gear on the Scribe page.
struct ScribeSettingsView: View {
    let controller: DictationController
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var calendar: CalendarService
    @EnvironmentObject var permissions: Permissions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SettingsCard(title: "Meeting detection", caption: "How Scribe notices that a meeting is starting or has ended") {
                SettingRow(title: "Notify before scheduled meetings start",
                           detail: calendarConnected ? "A reminder above the Flow Bar for meetings in your calendar."
                                                     : "Connect your calendar to get reminders for scheduled meetings.") {
                    if calendarConnected {
                        Picker("", selection: $settings.settings.scribeReminderLead) {
                            ForEach(MeetingReminderLead.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    } else {
                        ConnectCalendarButton()
                    }
                }
                RowDivider()
                SettingRow(title: "Show your next meeting in the menu bar",
                           detail: "The meeting name and a countdown next to the Shout icon.") {
                    SwitchControl(isOn: $settings.settings.scribeShowNextMeeting)
                }
                .disabled(!calendarConnected)
                RowDivider()
                SettingRow(title: "Automatically detect any call",
                           detail: "Asks if you want to take notes when Zoom, Teams, FaceTime, Slack huddles or a Meet tab start using the microphone.") {
                    SwitchControl(isOn: $settings.settings.scribeDetectCalls.animation(.easeOut(duration: 0.15)))
                }
                RowDivider()
                SettingRow(title: "Start Scribe automatically",
                           detail: settings.settings.scribeDetectCalls ? "Starts after a 10-second countdown instead of asking."
                                                                          : "Turn on “Automatically detect any call” to use this.") {
                    // Reads off while detection is off, since nothing can start it then.
                    SwitchControl(isOn: settings.settings.scribeDetectCalls ? $settings.settings.scribeAutoStart : .constant(false))
                }
                .disabled(!settings.settings.scribeDetectCalls)
                RowDivider()
                SettingRow(title: "Stop Scribe when a call ends", detail: "Stops on its own a few seconds after the call app releases the microphone.") {
                    SwitchControl(isOn: $settings.settings.scribeAutoStop.animation(.easeOut(duration: 0.15)))
                }
                RowDivider()
                SettingRow(title: "Check in during long meetings",
                           detail: settings.settings.scribeAutoStop
                               ? "Asks if you're still taking notes after an hour, when the meeting isn't in your calendar."
                               : "Turn on “Stop Scribe when a call ends” to use this.") {
                    // Check-ins belong to auto-stop, so this reads off while that is off.
                    SwitchControl(isOn: settings.settings.scribeAutoStop ? $settings.settings.scribeLongMeetingCheckIn : .constant(false))
                }
                .disabled(!settings.settings.scribeAutoStop)
                RowDivider()
                SettingRow(title: "Maximum recording length",
                           detail: "Scribe checks with you 5 minutes before it stops (2 minutes before with a 30-minute limit).") {
                    Picker("", selection: $settings.settings.scribeMaxMinutes) {
                        ForEach(ScribeController.maxLengthOptions, id: \.self) {
                            Text(ScribeController.lengthLabel(minutes: $0)).tag($0)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
            }

            SettingsCard(title: "While Scribe is active", caption: nil) {
                SettingRow(title: "Hide Notepad and Flow Bar from screen sharing",
                           detail: "They won't appear in screenshots, recordings or when you share your screen. Always ask for consent before transcribing.") {
                    SwitchControl(isOn: $settings.settings.scribeHideFromScreenCapture)
                }
            }

            SettingsCard(title: "Notepad", caption: nil) {
                SettingRow(title: "Open Notepad when starting Scribe", detail: "Shows your notes and the live transcript beside the call.") {
                    SwitchControl(isOn: $settings.settings.scribeOpenNotepad)
                }
                RowDivider()
                SettingRow(title: "Split the screen when joining",
                           detail: "Puts the meeting on the left and the Notepad on the right. Uses the Accessibility permission.") {
                    SwitchControl(isOn: $settings.settings.scribeSplitScreen)
                }
                RowDivider()
                ShortcutRow(title: "Keyboard shortcut", subtitle: "Start or stop the Scribe from any app", slot: .scribe,
                            combo: shortcut, controller: controller)
                    .settingRowPadding()
            }

            SettingsCard(title: "Transcript", caption: nil) {
                SettingRow(title: "Show live transcript", detail: "See the words appear while you record. When off, the Notepad opens on My Notes.") {
                    SwitchControl(isOn: $settings.settings.scribeShowLiveTranscript)
                }
                RowDivider()
                SettingRow(title: "Detect speaker names",
                           detail: "Names are read from the meeting app's window (Zoom, Meet, Teams or Slack) and stay on this Mac."
                               + (permissions.accessibility ? "" : " Needs the Accessibility permission.")) {
                    HStack(spacing: 10) {
                        if !permissions.accessibility && settings.settings.scribeDetectSpeakers {
                            Button("Allow…") { permissions.requestAccessibility() }.controlSize(.small)
                        }
                        SwitchControl(isOn: $settings.settings.scribeDetectSpeakers)
                    }
                }
                RowDivider()
                SettingRow(title: "Echo cancellation",
                           detail: "Removes the call's sound from your microphone so others aren't transcribed as you. Turn it off if other apps get quieter while recording.") {
                    SwitchControl(isOn: $settings.settings.scribeEchoCancellation)
                }
            }

            SettingsCard(title: "Summaries", caption: "Written on this Mac by the language model chosen in Models") {
                SettingRow(title: "Summarize meetings automatically",
                           detail: "Overview, decisions and next steps after every meeting longer than 5 minutes. Shorter ones get a Generate button.") {
                    SwitchControl(isOn: $settings.settings.scribeAutoSummarize)
                }
            }

            SettingsCard(title: "Consent", caption: "Let people know you're taking notes") {
                VStack(alignment: .leading, spacing: 8) {
                    PlaceholderEditor(text: $settings.settings.scribeConsentMessage, placeholder: "Consent message", minHeight: 64)
                        .frame(height: 76)
                    HStack {
                        CopyButton(text: settings.settings.scribeConsentMessage, label: "Copy message")
                        Spacer()
                        Button("Reset to Default") { settings.settings.scribeConsentMessage = AppSettings.defaultConsentMessage }
                            .disabled(settings.settings.scribeConsentMessage == AppSettings.defaultConsentMessage)
                    }
                    .controlSize(.small)
                    Text("Paste it into the meeting chat. The Notepad offers it while you record.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
    }

    private var calendarConnected: Bool { calendar.access == .granted }

    /// Clearing the shortcut is remembered, so the ⌥M default isn't added back.
    private var shortcut: Binding<KeyCombo> {
        Binding(get: { settings.settings.scribeShortcut }, set: { combo in
            var s = settings.settings
            s.scribeShortcut = combo
            s.scribeShortcutRemoved = combo.isEmpty
            settings.settings = s
        })
    }
}

/// "Connect Calendar…": asks for calendar access, or opens System Settings once it was answered (denied,
/// write-only or restricted), since the prompt only shows the first time.
struct ConnectCalendarButton: View {
    @EnvironmentObject var calendar: CalendarService
    var title = "Connect Calendar…"
    var body: some View {
        Button(title) {
            if calendar.access == .notDetermined {
                Task { _ = await calendar.requestAccess() }
            } else {
                calendar.openSettings()
            }
        }
    }
}
