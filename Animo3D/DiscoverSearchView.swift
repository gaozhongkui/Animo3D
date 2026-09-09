//
//  DiscoverSearchView.swift
//  Animo3D
//
//  Searching the community feed, on its own screen.
//
//  The search field used to sit above the browse grid and edit it in place, which made one screen
//  do two jobs badly: the category chips stayed on screen implying they still applied (they do
//  not - a query and a category are separate requests), the keyboard covered half the results, and
//  leaving a query behind meant the browse tab was no longer showing what it said it was.
//
//  Here the query owns the screen. No chips, results fill everything under the field, and closing
//  it leaves the browse grid exactly as it was - nothing is shared but the network client.
//

import SwiftUI

struct DiscoverSearchView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selectedModel: SketchfabModel?
    @State private var resultCount = 0
    @State private var loading = true
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                    TextField("Search 3D Inspiration", text: $query)
                        .font(.system(size: 15))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($fieldFocused)
                        .onSubmit { fieldFocused = false }
                    if !query.isEmpty {
                        Button {
                            query = ""
                            fieldFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button("Cancel") { dismiss() }
                    .font(.system(size: 15, weight: .medium))
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)

            ZStack {
                // No category binding: on this screen a query is the only filter, which is also why
                // there are no chips to imply otherwise.
                DiscoverViewControllerRepresentable(searchText: $query,
                                                    selectedCategory: .constant(""),
                                                    onModelSelected: { selectedModel = $0 },
                                                    onResults: { count, isLoading in
                                                        resultCount = count
                                                        loading = isLoading
                                                    })

                // Only once a search has actually come back empty. An empty grid on its own cannot
                // tell "nothing matched" from "still loading", and showing "no results" during the
                // request is worse than showing nothing.
                if !loading, resultCount == 0, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 30))
                            .foregroundStyle(.tertiary)
                        Text("No models match that search")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .fullScreenCover(item: $selectedModel) { model in
            ModelDetailView(model: model)
                .overlay(alignment: .topLeading) {
                    CircleButton(system: "xmark") { selectedModel = nil }
                        .padding(.leading, 20).padding(.top, 10)
                }
        }
        .task {
            // A beat after the cover settles: focusing during the presentation transition is
            // unreliable and sometimes brings the keyboard up without the caret.
            try? await Task.sleep(nanoseconds: 350_000_000)
            fieldFocused = true
        }
    }
}
