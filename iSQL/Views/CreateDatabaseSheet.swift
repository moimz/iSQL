import SwiftUI

/// 새 데이터베이스 (사이드바 하단바 +). 이름과 문자셋·콜레이션(서버 기본값) → CREATE DATABASE
struct CreateDatabaseSheet: View {
	let session: Session
	private var dialect: any SQLDialect { session.dialect }
	@Environment(\.dismiss) private var dismiss
	@State private var name = ""
	@State private var charset = ""
	@State private var collation = ""
	@State private var running = false
	@State private var failure: String?
	@FocusState private var focused: Bool

	private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
	private var exists: Bool { session.databases.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame } }
	private var canCreate: Bool { !trimmed.isEmpty && !exists && !running }

	private var sql: String {
		dialect.createDatabase(trimmed, charset: charset, collation: collation)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("새 데이터베이스").font(.headline)
			Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
				GridRow {
					label("이름")
					TextField("데이터베이스 이름", text: $name)
						.textFieldStyle(.roundedBorder)
						.focused($focused)
						.onSubmit { if canCreate { Task { await create() } } }
				}
				GridRow {
					label("문자셋")
					PopUp(selection: Binding(get: { charset }, set: pickCharset),
					      options: options(session.catalog.charsets.map(\.name), current: charset))
				}
				GridRow {
					label("콜레이션")
					PopUp(selection: $collation, options: options(session.catalog.collations(for: charset), current: collation))
				}
			}
			if exists {
				Label("이미 있는 데이터베이스입니다", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
			} else if !trimmed.isEmpty {
				Text(sql).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
			}
			if let f = failure {
				Label(f, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout).textSelection(.enabled)
			}
			HStack {
				Spacer()
				Button("취소", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
					.disabled(running)
				Button {
					Task { await create() }
				} label: {
					if running { ProgressView().controlSize(.small) } else { Text("만들기") }
				}
				.buttonStyle(.borderedProminent)
				.keyboardShortcut(.defaultAction)
				.disabled(!canCreate)
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 440)
		.interactiveDismissDisabled(running)
		.onAppear { focused = true }
		.task { await loadDefaults() }
	}

	private func label(_ s: String) -> some View {
		Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
	}

	private func options(_ list: [String], current: String) -> [(title: String, value: String?)] {
		var l = list
		if !current.isEmpty, !l.contains(current) { l.insert(current, at: 0) }
		return l.map { ($0, $0) }
	}

	private func pickCharset(_ cs: String) {
		charset = cs
		if session.catalog.charset(of: collation) != cs {
			collation = session.catalog.defaultCollation(for: cs) ?? session.catalog.collations(for: cs).first ?? ""
		}
	}

	/// 서버 기본 문자셋·콜레이션
	@MainActor
	private func loadDefaults() async {
		try? await session.loadCatalogIfNeeded()
		guard charset.isEmpty else { return }
		// 서버 설정에 정해 둔 기본값이 먼저
		if let cs = session.server?.defaultCharset, !cs.isEmpty {
			charset = cs
			collation = session.server?.defaultCollation.flatMap { $0.isEmpty ? nil : $0 } ?? session.catalog.defaultCollation(for: cs) ?? ""
			return
		}
		let r = (try? await session.meta.serverDefaults(session.query)) ?? nil
		charset = r?.charset ?? ""
		collation = r?.collation ?? ""
	}

	@MainActor
	private func create() async {
		guard canCreate else { return }
		running = true
		failure = nil
		defer { running = false }
		do {
			_ = try await session.query(sql)
		} catch {
			failure = error.localizedDescription
			return
		}
		await session.databaseCreated(trimmed)
		dismiss()
	}
}
