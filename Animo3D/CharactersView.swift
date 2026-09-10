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
    // The segment lives in the router, not in local state, so Home can deep-link straight to
    // Community - see AppRouter.
    @ObservedObject private var router = AppRouter.shared
    @Namespace private var animation

    private var seg: AppRouter.CharactersSegment { router.charactersSegment }

    var body: some View {
        VStack(spacing: 0) {
            // Custom refined segmented control
            HStack(spacing: 0) {
                pickerItem(title: "My Characters", segment: .mine)
                pickerItem(title: "Community", segment: .community)
            }
            .padding(4)
            .background(Color(.secondarySystemFill), in: Capsule())
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)

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
        .background(Color(.systemBackground).ignoresSafeArea())
        .trackScreen("Characters")
    }

    private func pickerItem(title: LocalizedStringKey, segment: AppRouter.CharactersSegment) -> some View {
        let isOn = seg == segment
        return Text(title)
            .font(.system(size: 14, weight: isOn ? .bold : .medium))
            .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background {
                if isOn {
                    // The knob has to be the page background, not literal white: white behind
                    // `.primary` text is white-on-white once the phone is in dark mode.
                    Capsule()
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                        .matchedGeometryEffect(id: "picker", in: animation)
                }
            }
            .contentShape(Capsule())
            .onTapGesture {
                HapticManager.selection()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
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
                            CharacterCard(name: c.name, characterKey: c.id, tint: tints[i % tints.count])
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
}

struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
