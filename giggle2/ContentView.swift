import SwiftUI

struct ContentView: View {
    // Sidebar state
    @State private var section: AppSection = .manager
    @State private var tool: Tool = .gigs
    @State private var selectedGent = 1

    // Data for gigs
    @State private var managerGigs: [Gig] = []
    @State private var gentGigs: [Gig] = []
    @State private var selection: Gig?
    @State private var justCreatedGigId: String?

    // Realtime (gent)
    @StateObject private var rt = Realtime()

    var body: some View {
        // Outer split view: sidebar + main content
        NavigationSplitView {
            SidebarView(
                section: $section,
                tool: $tool,
                selectedGent: $selectedGent,
                forceRefresh: {
                    if tool == .gigs {
                        if section == .manager { Task { await refreshManager() } }
                        else { Task { await refreshGent() } }
                    }
                },
                connectedGentId: rt.connectedGentId
            )
            .frame(minWidth: 240)

        } detail: {
            switch tool {
            case .gigs:
                GigsToolView(role: section == .manager ? .manager : .gent,
                             selectedGent: $selectedGent,
                             rt: rt)
                
            case .calendar:
                CalendarToolView(role: section == .manager ? .manager : .gent)

            case .accounting:
                AccountingToolView() // Only shown when section == .manager in sidebar

            case .availability:
                AvailabilityToolView(role: section == .manager ? .manager : .gent)
            }
        }
    }

    // MARK: - Helpers
    private var currentGigs: [Gig] {
        section == .manager ? managerGigs : gentGigs
    }

    private func refreshManager() async {
        guard let url = URL(string: "\(BASE_HTTP)/manager/gigs") else { return }
        struct Resp: Codable { let gigs: [Gig] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(Resp.self, from: data)
            await MainActor.run {
                managerGigs = decoded.gigs
                if let sel = selection, !managerGigs.contains(sel) { selection = nil }
            }
        } catch { /* ignore for demo */ }
    }

    private func refreshGent() async {
        let gentId = "gent-\(selectedGent)"
        guard let url = URL(string: "\(BASE_HTTP)/gent/\(gentId)/gigs") else { return }
        struct Resp: Codable { let gigs: [Gig] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(Resp.self, from: data)
            await MainActor.run {
                gentGigs = decoded.gigs
                if let sel = selection, !gentGigs.contains(sel) { selection = nil }
            }
        } catch { /* ignore for demo */ }
    }

    private func connectGentWS() {
        rt.onGigsChanged = { Task { await refreshGent() } }
        rt.connect(as: "gent-\(selectedGent)")
    }

    private func createNewGigAndEdit() async {
        // Backend requires date/email/fee; seed minimal valid gig.
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        struct CreateReq: Codable { let date: String; let client_email: String; let fee: Int }
        let payload = CreateReq(date: f.string(from: Date()), client_email: "new@example.com", fee: 0)

        guard let url = URL(string: "\(BASE_HTTP)/gigs") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(payload)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            let newGig = try JSONDecoder().decode(Gig.self, from: data)
            await MainActor.run {
                managerGigs.insert(newGig, at: 0)
                selection = newGig
                justCreatedGigId = newGig.id
            }
        } catch { /* ignore for demo */ }
    }
}

struct SidebarView: View {
    @Binding var section: AppSection
    @Binding var tool: Tool
    @Binding var selectedGent: Int
    var forceRefresh: () -> Void
    var connectedGentId: String?

    var body: some View {
        List {
            Section("Mode") {
                Picker("Mode", selection: $section) {
                    Text("Manager").tag(AppSection.manager)
                    Text("Gents").tag(AppSection.gent)
                }
                .pickerStyle(.segmented)
            }

            Section("Tool") {
                Picker("Tool", selection: $tool) {
                    Text("Gigs").tag(Tool.gigs)
                    Text("Calendar").tag(Tool.calendar)
                    if section == .manager {
                        Text("Accounting").tag(Tool.accounting)
                    }
                    Text("Availability").tag(Tool.availability)
                }
                .pickerStyle(.menu)
            }

            if section == .gent {
                Section("Gent") {
                    Picker("Logged in as", selection: $selectedGent) {
                        ForEach(1...5, id: \.self) { i in Text("gent-\(i)").tag(i) }
                    }
                    .pickerStyle(.menu)

                    Button("Force Refresh", action: forceRefresh)

                    if let gid = connectedGentId {
                        Text("Connected as \(gid)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct GigsToolView: View {
    let role: UserRole                 // .manager or .gent
    @Binding var selectedGent: Int     // used when role == .gent
    @ObservedObject var rt: Realtime

    @State private var gigs: [Gig] = []
    @State private var selection: Gig?
    @State private var justCreatedGigId: String?

    var body: some View {
        NavigationStack {
            List(gigs) { g in
                NavigationLink(value: g) { GigRow(gig: g) }
            }
            .navigationTitle(role == .manager ? "Manager • Gigs" : "Gents • Gigs")
            .toolbar {
                if role == .manager {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await createNewGigAndEdit() }
                        } label: { Label("New Gig", systemImage: "plus") }
                    }
                } else {
                    ToolbarItem(placement: .status) {
                        Text("gent-\(selectedGent)").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationDestination(for: Gig.self) { g in
                GigDetailView(role: role,
                              gig: g,
                              onSaved: role == .manager ? { Task { await refresh() } } : nil,
                              startInEdit: (role == .manager && g.id == justCreatedGigId))
            }
            .task { await refresh() }
            .onAppear {
                if role == .gent {
                    rt.onGigsChanged = { Task { await refresh() } }
                    rt.connect(as: "gent-\(selectedGent)")
                }
            }
            .onChange(of: selectedGent) { _ in
                if role == .gent {
                    rt.onGigsChanged = { Task { await refresh() } }
                    rt.connect(as: "gent-\(selectedGent)")
                    Task { await refresh() }
                }
            }
        }
    }

    // MARK: - Networking
    private func refresh() async {
        do {
            if role == .manager {
                guard let url = URL(string: "\(BASE_HTTP)/manager/gigs") else { return }
                struct Resp: Codable { let gigs: [Gig] }
                let (data, _) = try await URLSession.shared.data(from: url)
                let decoded = try JSONDecoder().decode(Resp.self, from: data)
                await MainActor.run { gigs = decoded.gigs }
            } else {
                let gentId = "gent-\(selectedGent)"
                guard let url = URL(string: "\(BASE_HTTP)/gent/\(gentId)/gigs") else { return }
                struct Resp: Codable { let gigs: [Gig] }
                let (data, _) = try await URLSession.shared.data(from: url)
                let decoded = try JSONDecoder().decode(Resp.self, from: data)
                await MainActor.run { gigs = decoded.gigs }
            }
        } catch { /* ignore for demo */ }
    }

    private func createNewGigAndEdit() async {
        // Backend requires date/email/fee. Seed minimal valid gig.
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        struct CreateReq: Codable { let date: String; let client_email: String; let fee: Int }
        let payload = CreateReq(date: f.string(from: Date()), client_email: "new@example.com", fee: 0)

        guard let url = URL(string: "\(BASE_HTTP)/gigs") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(payload)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            let newGig = try JSONDecoder().decode(Gig.self, from: data)
            await MainActor.run {
                gigs.insert(newGig, at: 0)
                justCreatedGigId = newGig.id
                selection = newGig   // so NavigationStack pushes detail
            }
        } catch { /* ignore for demo */ }
    }

    
}

struct CalendarToolView: View {
    let role: UserRole
    var body: some View {
        VStack(spacing: 12) {
            Text(role == .manager ? "Manager • Calendar" : "Gents • Calendar").font(.title2)
            Text("Calendar UI goes here.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct AccountingToolView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Manager • Accounting").font(.title2)
            Text("Accounting UI goes here.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct AvailabilityToolView: View {
    let role: UserRole
    var body: some View {
        VStack(spacing: 12) {
            Text(role == .manager ? "Manager • Availability" : "Gents • Availability").font(.title2)
            Text("Availability UI goes here.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
