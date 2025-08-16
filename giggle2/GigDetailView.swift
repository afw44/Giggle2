//
//  GigDetailView.swift
//  giggle2
//
//  Created by Alexander Weiss on 14/08/2025.
//

import SwiftUI

enum UserRole { case manager, gent }

struct GigDetailView: View {
    let role: UserRole
    @State var gig: Gig
    var onSaved: (() -> Void)? = nil

    // --- Edit mode state (manager only) ---
    @State private var isEditing = false
    @State private var dateText = ""
    @State private var clientEmail = ""
    @State private var feePounds = ""          // e.g. "250.00"
    @State private var isSaving = false
    @State private var errorMessage: String?
    var startInEdit: Bool = false          // <—


    // If you also show team here, keep your state for it:
    @State private var assigned: Set<String> = []

    var body: some View {
        Form {
                    Section("Details") {
                        detailsSectionContent
                    }
                }
                .navigationTitle("Gig")
                .task {
                    if role == .manager, startInEdit, !isEditing {
                        beginEdit()                 // <— auto-enter edit mode
                    }
                    if let g = gig.gents { assigned = Set(g) }
                

            // If you also show “Team”, keep that Section here…
        }
        .navigationTitle("Gig")
        .toolbar {
            if role == .manager {
                ToolbarItem(placement: .primaryAction) {
                    if isEditing {
                        HStack(spacing: 8) {
                            Button("Cancel") { cancelEdit() }
                            Button("Save")   { Task { await saveEdits() } }
                                .disabled(!canSave)
                        }
                    } else {
                        Button("Edit") { beginEdit() }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let msg = errorMessage {
                Text(msg)
                    .padding(8)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 8)
            }
        }
        .task {
            if let g = gig.gents { assigned = Set(g) }
        }
    }

    // MARK: - Section content (fixes the builder error)
    @ViewBuilder
    private var detailsSectionContent: some View {
        if role == .manager && isEditing {
            TextField("Date (YYYY-MM-DD)", text: $dateText)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())

            TextField("Client Email", text: $clientEmail)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

            TextField("Fee (GBP)", text: $feePounds)
                .textFieldStyle(.roundedBorder)
        } else {
            // If LabeledContent still triggers issues in your SDK,
            // replace each with an HStack(label/value) pair.
            LabeledContent("Date") { Text(gig.date) }
            LabeledContent("Client") { Text(gig.client_email) }
            LabeledContent("Fee") { Text(formatCurrencyCents(gig.fee)).monospaced() }
        }
    }


    // MARK: - Edit flow
    private func beginEdit() {
        dateText = gig.date
        clientEmail = gig.client_email
        feePounds = String(format: "%.2f", Double(gig.fee) / 100.0)
        errorMessage = nil
        isEditing = true
    }

    private func cancelEdit() {
        isEditing = false
        errorMessage = nil
    }

    private var canSave: Bool {
        !dateText.trimmingCharacters(in: .whitespaces).isEmpty &&
        !clientEmail.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Decimal(string: feePounds) != nil)
    }

    private func saveEdits() async {
        guard canSave else { return }
        isSaving = true; defer { isSaving = false }

        // Build PATCH payload of changed fields only
        var payload: [String: Any] = [:]
        if dateText != gig.date { payload["date"] = dateText }
        if clientEmail != gig.client_email { payload["client_email"] = clientEmail }
        if let feeDec = Decimal(string: feePounds) {
            let newCents = NSDecimalNumber(decimal: feeDec * 100).intValue
            if newCents != gig.fee { payload["fee"] = newCents }
        }

        // Nothing changed?
        if payload.isEmpty { isEditing = false; return }

        guard let url = URL(string: "\(BASE_HTTP)/gigs/\(gig.id)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [])

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                throw URLError(.badServerResponse)
            }
            // Update local gig from server response
            let updated = try JSONDecoder().decode(Gig.self, from: data)
            await MainActor.run {
                self.gig = updated
                self.isEditing = false
                self.errorMessage = nil
                self.onSaved?()      // ask parent to refresh list, if provided
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Couldn’t save changes. Check fields and try again."
            }
        }
    }

    // MARK: - Utils
    private func formatCurrencyCents(_ cents: Int) -> String {
        let pounds = Double(cents) / 100.0
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "GBP"
        return f.string(from: NSNumber(value: pounds)) ?? "£\(pounds)"
    }
}

/// Simple wrapping HStack for tags
struct WrapHStack<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        var width: CGFloat = 0
        var height: CGFloat = 0
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                content()
                    .fixedSize()
                    .alignmentGuide(.leading) { d in
                        if (abs(width - d.width) > geo.size.width) {
                            width = 0
                            height -= d.height + spacing
                        }
                        let result = width
                        width -= d.width + spacing
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = height
                        return result
                    }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GigRow: View {
    let gig: Gig
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Date: \(gig.date)").font(.headline)
            HStack {
                Text("Client: \(gig.client_email)")
                Spacer()
                Text(currency(gig.fee)).monospaced()
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
    }
    private func currency(_ cents: Int) -> String {
        let pounds = Double(cents) / 100.0
        return String(format: "£%.2f", pounds)
    }
}

struct ContentPlaceholder: View {
    var title: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.and.text.magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


