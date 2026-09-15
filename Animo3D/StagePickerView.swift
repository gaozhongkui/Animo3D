//
//  StagePickerView.swift
//  Animo3D
//
//  Where the performance happens, chosen from a page of its own.
//
//  This started as two chips at the bottom of the stage, which was the right size for the two
//  stages that existed and the wrong shape for what is coming: the catalogue can add skies at any
//  time, and a row of pills has nowhere to put a picture of one, a download, or a name that is
//  longer than a word. A page can.
//
//  The two stages that ship in the app are pinned to the top and are always there - they need no
//  network and their light was tuned by hand. Everything the catalogue serves comes after them, and
//  what the user made from their own photographs sits in between, because it is theirs.
//

import PhotosUI
import SwiftUI

struct StagePickerView: View {
    /// The stage in use, by id. Written straight back through `@AppStorage` by the stage screen.
    @Binding var selection: String
    var onPick: (String) -> Void
    var onClose: () -> Void

    @ObservedObject private var library = StageLibrary.shared
    @ObservedObject private var assets = RemoteAssets.shared
    @ObservedObject private var store = ProStore.shared

    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var importError: String?
    @State private var showPaywall = false
    @State private var renaming: UserStage?
    @State private var draftName = ""

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    /// The one stage anyone can use. Changing where you dance is what Pro buys here, so the stage
    /// the app opens in stays free - a locked default would mean a paywall between the user and the
    /// screen they were already on.
    private var isLocked: (String) -> Bool {
        { id in !store.isPro && id != CharacterSceneController.Stage.plaza.id }
    }

    private func choose(_ id: String) {
        if isLocked(id) {
            Track.log(.lockedItemTapped, ["kind": "stage", "id": id])
            showPaywall = true
        } else {
            onPick(id)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(CharacterSceneController.Stage.all, id: \.id) { built in
                        card(id: built.id, name: Text(LocalizedStringKey(built.name)), badge: nil)
                    }
                    ForEach(library.userStages) { mine in
                        // Not a LocalizedStringKey: this name is the user's own words, and looking
                        // it up in the app's strings would be looking for a translation of it.
                        card(id: mine.id, name: Text(mine.name), badge: "photo.fill")
                            .contextMenu {
                                Button {
                                    draftName = mine.name
                                    renaming = mine
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) { library.delete(mine) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    ForEach(assets.stages) { item in
                        card(id: item.id, name: Text(item.name), badge: nil)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Scene")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { onClose() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    // A picture imported without Pro would be a stage the user cannot then stand
                    // in, so the import asks the same question the stages do.
                    if store.isPro {
                        PhotosPicker(selection: $photo, matching: .images, photoLibrary: .shared()) {
                            if importing { ProgressView() } else { Image(systemName: "plus") }
                        }
                        .disabled(importing)
                    } else {
                        Button {
                            Track.log(.lockedItemTapped, ["kind": "stage_import"])
                            showPaywall = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
        }
        // Whatever is in the catalogue but not yet on disk has no card art, because the card art is
        // a crop of the sky itself. Fetch them while the user is looking at the page.
        .task(id: assets.stages.count) {
            for item in assets.stages where RemoteAssets.shared.localURL(for: item.sky.assetName) == nil {
                _ = try? await RemoteAssets.shared.ensureDownloaded(item.sky)
                await library.loadThumbnail(for: item.id)
            }
        }
        .onChange(of: photo) { item in
            guard let item else { return }
            importing = true
            Task {
                defer { importing = false; photo = nil }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    importError = StageLibrary.ImportError.unreadable.errorDescription
                    return
                }
                do {
                    let stage = try library.importPhoto(image, name: "My Scene")
                    onPick(stage.id)
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView(onClose: { showPaywall = false }, source: "stage")
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil },
                                              set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draftName)
            Button("Save") {
                if let mine = renaming { library.rename(mine, to: draftName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Import", isPresented: Binding(get: { importError != nil },
                                              set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    /// `name` is a `Text` rather than a string so each caller decides whether it is translated:
    /// the two built-in stages are named in the app's own words, and what the user called their
    /// photograph is not something to look up in a strings file.
    private func card(id: String, name: Text, badge: String?) -> some View {
        let picked = selection == id
        let art = library.thumbs[id]

        return Button {
            HapticManager.light()
            choose(id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    if let art {
                        Image(uiImage: art).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        // Not downloaded yet: a card that says so beats an empty grey hole.
                        Rectangle().fill(Color(.secondarySystemBackground))
                        ProgressView()
                    }
                }
                .frame(height: 104)
                .frame(maxWidth: .infinity)
                .task { await library.loadThumbnail(for: id) }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                // The ring goes outside the clip, and draws inwards: drawn inside it, half its
                // width was cut away and what was left read as a frayed edge rather than a border.
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(picked ? Color.accentColor : Color.primary.opacity(0.08),
                                      lineWidth: picked ? 3 : 0.5)
                }
                .overlay(alignment: .topTrailing) {
                    if isLocked(id) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(8)
                    } else if picked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.accentColor, in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                            .padding(8)
                    } else if let badge {
                        // Whose picture this is, when it is one of the user's own.
                        Image(systemName: badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(.black.opacity(0.4), in: Circle())
                            .padding(8)
                    }
                }
                .shadow(color: .black.opacity(picked ? 0.18 : 0.06),
                        radius: picked ? 8 : 3, y: picked ? 3 : 1)

                name
                    .font(.subheadline.weight(picked ? .semibold : .regular))
                    .foregroundStyle(picked ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
    }
}
