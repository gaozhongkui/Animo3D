//
//  CharactersView.swift
//  Animo3D
//
//  The "Characters" tab: the main flow's armory.
//  - My characters: the bundled characters that can dance. Tap one to dance with it.
//  - Community: browse Sketchfab / view in AR.
//

import SwiftUI

struct CharactersView: View {
    @State private var seg = 0
    @Namespace private var animation

    var body: some View {
        VStack(spacing: 0) {
            // Custom refined segmented control
            HStack(spacing: 0) {
                pickerItem(title: "My Characters", tag: 0)
                pickerItem(title: "Community", tag: 1)
            }
            .padding(4)
            .background(Color(.secondarySystemFill), in: Capsule())
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)

            ZStack {
                if seg == 0 {
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
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private func pickerItem(title: LocalizedStringKey, tag: Int) -> some View {
        Text(title)
            .font(.system(size: 14, weight: seg == tag ? .bold : .medium))
            .foregroundStyle(seg == tag ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background {
                if seg == tag {
                    Capsule()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                        .matchedGeometryEffect(id: "picker", in: animation)
                }
            }
            .contentShape(Capsule())
            .onTapGesture {
                HapticManager.selection()
                seg = tag
            }
    }
}

private struct PickedCharacter: Identifiable { let id: String; let name: String }

/// My characters: the library of characters that can dance. Tap one to enter the dance studio with it.
struct MyCharactersView: View {
    @ObservedObject private var remoteAssets = RemoteAssets.shared
    @State private var picked: PickedCharacter?
    private let cols = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    private let tints: [Color] = [.blue, .pink, .purple, .orange, .teal, .indigo, .green, .red]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("3D Virtual Dancers")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .padding(.horizontal)

                LazyVGrid(columns: cols, spacing: 18) {
                    ForEach(Array(remoteAssets.characters.enumerated()), id: \.element.id) { i, c in
                        Button {
                            HapticManager.light()
                            picked = PickedCharacter(id: c.id, name: c.name)
                        } label: {
                            characterCard(c.name, key: c.id, tint: tints[i % tints.count])
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
                .padding(.horizontal)
            }
            .padding(.top, 4)
            .padding(.bottom, 30)
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

    private func characterCard(_ name: String, key: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                CharacterThumbView(characterKey: key, tint: tint)
                    .aspectRatio(3.0/4.0, contentMode: .fill)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                LinearGradient(colors: [.clear, .black.opacity(0.4)],
                               startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                HStack {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .padding(6)
                        .background(.white, in: Circle())
                        .foregroundStyle(tint)

                    Text("Dance")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(10)
            }
            .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)

            Text(name)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .padding(.horizontal, 4)
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
