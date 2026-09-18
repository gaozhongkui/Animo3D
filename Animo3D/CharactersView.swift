//
//  CharactersView.swift
//  Animo3D
//
//  The "Characters" tab: the main flow's armory.
//  - My characters: the bundled characters that can dance. Tap one to dance with it.
//  - Community: browse Sketchfab / view in AR.
//

import SwiftUI
import UniformTypeIdentifiers

struct CharactersView: View {
    // The segment lives in the router, not in local state, so Home can deep-link straight to
    // Community - see AppRouter.
    @ObservedObject private var router = AppRouter.shared
    @Namespace private var animation

    private var seg: AppRouter.CharactersSegment { router.charactersSegment }

    // 专属流体悬浮舱蓝紫渐变
    private var communityGradient: LinearGradient {
        LinearGradient(colors: [Color(rgb: 0x6366F1), Color(rgb: 0xA855F7)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Refined Segmented Fluid Capsule (流体悬浮舱分段选择器)
            HStack(spacing: 0) {
                pickerItem(title: "My Characters", segment: .mine)
                pickerItem(title: "Community", segment: .community)
            }
            .padding(4)
            .background(Color.white.opacity(0.04)) // 精致毛玻璃底色
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.06), lineWidth: 1) // 极细呼吸光边框
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 20)

            ZStack {
                if seg == .mine {
                    MyCharactersView()
                        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                              removal: .move(edge: .leading).combined(with: .opacity)))
                } else {
                    DiscoverView()
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                              removal: .move(edge: .trailing).combined(with: .opacity)))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: seg)
        }
        // 升级全量暗黑宇宙深邃星空舞台背景
        .background(Color(rgb: 0x0B0A12).ignoresSafeArea())
        .trackScreen("Characters")
    }

    private func pickerItem(title: LocalizedStringKey, segment: AppRouter.CharactersSegment) -> some View {
        let isOn = seg == segment
        return Text(title)
            .font(.system(size: 14, weight: isOn ? .bold : .medium))
            // 选中的一瞬间文字进行高光反白
            .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.55))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background {
                if isOn {
                    // 滑块升级为极具科技流体张力的霓虹渐变悬浮舱
                    Capsule()
                        .fill(communityGradient)
                        .shadow(color: Color(rgb: 0x6366F1).opacity(0.35), radius: 8, x: 0, y: 3)
                        .matchedGeometryEffect(id: "picker", in: animation)
                }
            }
            .contentShape(Capsule())
            .onTapGesture {
                HapticManager.selection()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    router.charactersSegment = segment
                }
            }
    }
}

private struct PickedCharacter: Identifiable { let id: String; let name: String }

/// My characters: the library of characters that can dance. Tap one to enter the dance studio with it.
struct MyCharactersView: View {
    @ObservedObject private var remoteAssets = RemoteAssets.shared
    @State private var picked: PickedCharacter?
    @State private var showImporter = false
    @State private var importing = false
    @State private var importError: String?
    @State private var pendingDelete: PickedCharacter?
    private let cols = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]


    /// Characters the user brought in themselves - the only ones that can be deleted.
    private var isImported: (String) -> Bool {
        let ids = Set(remoteAssets.userCharacters.map(\.id))
        return { ids.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("3D Virtual Dancers")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Spacer()
                    // This is the armory, which is where bringing your own model belongs. It used
                    // to be the first tile of the studio's character grid - a dashed placeholder
                    // ahead of every real dancer, on the one screen whose job is picking a dancer
                    // fast, and with nowhere to manage what had been imported.
                    Button {
                        HapticManager.light()
                        showImporter = true
                    } label: {
                        if importing {
                            ProgressView().frame(width: 32, height: 32)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 32, height: 32)
                                .background(Color(.secondarySystemFill), in: Circle())
                        }
                    }
                    .disabled(importing)
                    .accessibilityLabel("Import a VRM model")
                }
                .padding(.horizontal)

                LazyVGrid(columns: cols, spacing: 18) {
                    ForEach(Array(remoteAssets.characters.enumerated()), id: \.element.id) { i, c in
                        Button {
                            HapticManager.light()
                            picked = PickedCharacter(id: c.id, name: c.name)
                        } label: {
                            CharacterCard(name: c.name, characterKey: c.id, style: i)
                        }
                        .buttonStyle(CardButtonStyle())
                        .contextMenu {
                            if isImported(c.id) {
                                Button(role: .destructive) {
                                    pendingDelete = PickedCharacter(id: c.id, name: c.name)
                                } label: { Label("Remove", systemImage: "trash") }
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.top, 4)
            .padding(.bottom, 30)
        }
        // `.data`, not a VRM type: the system has no type registered for the extension, so
        // `UTType(filenameExtension: "vrm")` is nil and there is nothing narrower to ask for. The
        // real check is in the importer, which parses the file before keeping it.
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
            guard let url = try? result.get() else { return }
            importing = true
            Task {
                do {
                    try await remoteAssets.importLocalVRM(at: url)
                } catch {
                    importError = error.localizedDescription
                }
                importing = false
            }
        }
        .alert("Could not import", isPresented: Binding(get: { importError != nil },
                                                        set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("Remove this character?", isPresented: Binding(get: { pendingDelete != nil },
                                                             set: { if !$0 { pendingDelete = nil } })) {
            Button("Remove", role: .destructive) {
                if let p = pendingDelete { remoteAssets.deleteUserCharacter(p.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("\(pendingDelete?.name ?? "") and its model file will be deleted from this device.")
        }
        .fullScreenCover(item: $picked) { p in
            NavigationStack {
                DanceStudioView(initialCharacter: p.id)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { picked = nil } label: {
                                Image(systemName: "xmark").font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
            }
        }
    }
}

struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
