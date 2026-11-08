// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import AppKit
import SwiftUI

/// PIN sign-in, then server choice, then the profile picker when the Plex Home has several users.
/// Parity source: IOSPlexConnectionSheet in RivuletiOS/Shell/IOSAccountViews.swift.
struct MacPlexSignInSheet: View {
    @EnvironmentObject private var plex: PlexSession
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var choosingProfile = false
    @State private var lastError: String?
    @State private var connectingID: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).padding(.top, 16)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    if !plex.isSignedIn { plex.cancelSignIn() }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 440, height: 400)
        .task {
            if plex.state == .signedOut { await plex.retrySignIn() }
        }
        .onChange(of: plex.state) { _, state in
            switch state {
            case .failed(let message):
                lastError = message
            case .requestingPIN, .waitingForPIN, .findingServers, .selectingServer:
                lastError = nil
            case .connected:
                if profiles.hasMultipleProfiles { choosingProfile = true } else { dismiss() }
            case .signedOut:
                break
            }
        }
        .sheet(isPresented: $choosingProfile, onDismiss: { dismiss() }) { MacProfilePickerSheet() }
    }

    private var title: String {
        plex.state == .selectingServer ? String(localized: "Choose a Server") : String(localized: "Sign In to Plex")
    }

    @ViewBuilder
    private var content: some View {
        switch plex.state {
        case .waitingForPIN:
            pinStep
        case .selectingServer:
            List(plex.availableServers) { server in
                Button {
                    connectingID = server.id
                    Task {
                        await plex.selectServer(server)
                        connectingID = nil
                    }
                } label: {
                    MacServerRow(server: server, isConnecting: connectingID == server.id)
                }
                .buttonStyle(.plain)
                .disabled(connectingID != nil)
            }
        case .failed(let message):
            failure(message)
        case .signedOut where lastError != nil:
            failure(lastError ?? "")
        case .connected:
            ContentUnavailableView("Signed In", systemImage: "checkmark.circle.fill")
        default:
            ProgressView()
        }
    }

    private var pinStep: some View {
        VStack(spacing: 20) {
            Text("Open plex.tv/link and sign in. If it asks for a code, enter this one.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let code = plex.pinCode {
                Text(code)
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .tracking(6)
                    .textSelection(.enabled)
                    .accessibilityLabel(code.map(String.init).joined(separator: " "))

                HStack(spacing: 12) {
                    if let url = plex.authenticationURL {
                        Button { openURL(url) } label: { Label("Open plex.tv/link", systemImage: "safari") }
                            .buttonStyle(.borderedProminent)
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    } label: { Label("Copy Code", systemImage: "doc.on.doc") }
                }
                .controlSize(.large)
            }

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to sign in").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(24)
    }

    private func failure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t Sign In", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await plex.retrySignIn() } }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// A Plex server with a checkmark when current and a spinner while connecting.
struct MacServerRow: View {
    let server: PlexDevice
    var isCurrent = false
    var isConnecting = false

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).foregroundStyle(.primary)
                    if server.owned == false, let owner = server.sourceTitle {
                        Text("Shared by \(owner)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: server.owned == false ? "person.2" : "server.rack")
            }
            Spacer()
            if isConnecting {
                ProgressView().controlSize(.small)
            } else if isCurrent {
                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// A labelled form row for an address, name or login.
struct MacFormField: View {
    enum Kind { case text, url, username, password }

    let label: LocalizedStringKey
    @Binding var text: String
    let prompt: LocalizedStringKey
    let kind: Kind

    init(_ label: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey, kind: Kind = .text) {
        self.label = label
        self._text = text
        self.prompt = prompt
        self.kind = kind
    }

    var body: some View {
        if kind == .password {
            SecureField(label, text: $text, prompt: Text(prompt))
        } else {
            TextField(label, text: $text, prompt: Text(prompt))
                .autocorrectionDisabled(kind != .text)
        }
    }
}

