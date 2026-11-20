import SwiftUI
import AppKit

/// 설정 창 > 사용자 계정 (보기만): MySQL 계정 화면(UserAccountsView)과 같은 모양 — 왼쪽 목록, 오른쪽 탭 상자.
/// 만들기·고치기 버튼은 없다 (사용자 2026-11-20: SQL Server 는 일단 보기만, 고치기는 쿼리 패널에서)
struct AccountOverviewView: View {
	let session: Session
	@State private var overview = AccountOverview()
	@State private var loading = false
	@State private var loaded = false
	@State private var error: String?
	@State private var selectedID: String?
	@State private var detailTab = 0

	private var selected: AccountInfo? { overview.accounts.first { $0.id == selectedID } }

	var body: some View {
		Group {
			if let error {
				ContentUnavailableView {
					Label("사용자 계정을 볼 수 없습니다", systemImage: "lock")
				} description: {
					Text(error).textSelection(.enabled)
				} actions: {
					Button("새로고침") { Task { await load() } }.keyboardShortcut("r")
				}
			} else {
				VStack(alignment: .leading, spacing: 10) {
					HStack(alignment: .top, spacing: 16) {
						list.frame(width: 250)
						detail.frame(maxWidth: .infinity, maxHeight: .infinity)
					}
					HStack(spacing: 10) {
						Button { Task { await load() } } label: {
							if loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
						}
						.buttonStyle(.bordered)
						.buttonBorderShape(.roundedRectangle)
						.keyboardShortcut("r")
						.help("새로고침 (⌘R)")
						Label("보기만 · 만들기와 고치기는 쿼리 패널에서", systemImage: "lock.fill")
							.font(.callout).foregroundStyle(.secondary)
						if let note = overview.note {
							Text(note).font(.callout).foregroundStyle(.orange).lineLimit(2).help(note)
						}
					}
				}
				.padding(20)
			}
		}
		.task { if !loaded { await load() } }
	}

	@MainActor
	private func load() async {
		guard !loading else { return }
		loading = true
		defer { loading = false; loaded = true }
		do {
			overview = try await session.meta.accountOverview(session.query)
			error = nil
			if selectedID == nil || selected == nil {
				selectedID = overview.accounts.first { $0.name == overview.current }?.id ?? overview.accounts.first?.id
			}
		} catch {
			self.error = error.localizedDescription
		}
	}

	private var list: some View {
		List(selection: $selectedID) {
			ForEach(overview.accounts) { a in
				HStack(spacing: 10) {
					AccountTile(locked: a.disabled, system: a.system)
					VStack(alignment: .leading, spacing: 2) {
						Text(a.name).font(.system(size: 14)).lineLimit(1)
						Text(a.kind).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
					}
					Spacer(minLength: 0)
					if a.name == overview.current {
						Text("접속 중").font(.caption.weight(.semibold)).foregroundStyle(selectedID == a.id ? Color.white : Color.green)
					}
				}
				.padding(.vertical, 5)
				.listRowSeparator(.hidden)
				.tag(a.id)
			}
		}
		.listStyle(.bordered(alternatesRowBackgrounds: false))
		.overlay { if loading && overview.accounts.isEmpty { ProgressView() } }
		.padding(.top, 11)
	}

	@ViewBuilder private var detail: some View {
		if let a = selected {
			BoxTabView(titles: ["일반", overview.roleTitle, overview.databaseTitle, overview.permissionTitle], selection: $detailTab) { i in
				switch i {
				case 1: AnyView(page { lines(a.roles, empty: "역할 없음 (public 만)") })
				case 2: AnyView(page { databases(a) })
				case 3: AnyView(page { lines(a.permissions, empty: "직접 받은 권한 없음", mono: true) })
				default: AnyView(page { general(a) })
				}
			}
		} else {
			ContentUnavailableView("계정을 고르세요", systemImage: "person.2", description: Text("\(overview.accounts.count)개 계정"))
				.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
		}
	}

	private func page<C: View>(@ViewBuilder _ content: () -> C) -> some View {
		ScrollView {
			content()
				.padding(16)
				.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	private func general(_ a: AccountInfo) -> some View {
		Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
			GridRow {
				Text("이름:").gridColumnAlignment(.trailing)
				HStack(spacing: 8) {
					Text(a.name).font(.body.monospaced()).textSelection(.enabled)
					if a.name == overview.current { Text("지금 접속한 계정").font(.caption.weight(.semibold)).foregroundStyle(.green) }
				}
			}
			ForEach(a.fields, id: \.self) { f in
				GridRow {
					Text(f.label + ":").gridColumnAlignment(.trailing)
					if f.label == "상태" {
						HStack(spacing: 8) {
							Circle().fill(a.disabled ? Color.orange : Color.green).frame(width: 8, height: 8)
							Text(f.value)
						}
					} else {
						Text(f.value).foregroundStyle(.secondary).textSelection(.enabled)
					}
				}
			}
		}
	}

	private func lines(_ items: [String], empty: String, mono: Bool = false) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			if items.isEmpty {
				Text(empty).foregroundStyle(.secondary)
			} else {
				ForEach(items, id: \.self) { s in
					Text(s).font(mono ? .body.monospaced() : .body).textSelection(.enabled)
				}
			}
		}
	}

	/// DB 마다: DB 이름 · 그 안의 사용자 이름(로그인과 다를 수 있다) · 기본 스키마 · 역할
	private func databases(_ a: AccountInfo) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			if a.databases.isEmpty {
				Text("이어진 DB 사용자가 없습니다 (기본 DB 외에는 들어갈 수 없거나, sysadmin 이면 모든 DB 를 dbo 로 씁니다)")
					.foregroundStyle(.secondary)
			}
			ForEach(a.databases, id: \.self) { d in
				VStack(alignment: .leading, spacing: 4) {
					HStack(spacing: 6) {
						Image(systemName: "cylinder").foregroundStyle(.secondary)
						Text(d.database).font(.headline)
						Text("사용자 \(d.user)" + (d.schema.isEmpty ? "" : " · 기본 스키마 \(d.schema)"))
							.foregroundStyle(.secondary)
					}
					Text(d.roles.isEmpty ? "역할 없음 (public 만)" : d.roles.joined(separator: ", "))
						.foregroundStyle(d.roles.isEmpty ? .secondary : .primary)
						.padding(.leading, 22)
						.textSelection(.enabled)
				}
			}
		}
	}
}
