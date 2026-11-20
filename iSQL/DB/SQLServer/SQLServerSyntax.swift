import Foundation

extension SQLSyntax {
	/// SQL Server (T-SQL): [이름] (따옴표 " 도 이름), '글자' 는 '' 로 (\ 는 그냥 글자), -- 와 /* */ 주석.
	/// 프로시저·함수·트리거·뷰 정의와 DECLARE 로 시작하는 글은 ; 로 나누지 않고 GO 줄이나 글 끝에서 끝난다
	static let sqlServer: SQLSyntax = {
		let keywords = """
		SELECT FROM WHERE AND OR NOT IN IS NULL LIKE BETWEEN EXISTS AS ON JOIN LEFT RIGHT INNER OUTER FULL CROSS APPLY \
		GROUP BY ORDER ASC DESC HAVING DISTINCT TOP PERCENT TIES UNION ALL EXCEPT INTERSECT INSERT INTO VALUES UPDATE SET DELETE \
		OUTPUT MERGE MATCHED USING CREATE ALTER DROP TRUNCATE TABLE VIEW INDEX CLUSTERED NONCLUSTERED SCHEMA DATABASE PROCEDURE PROC \
		FUNCTION TRIGGER RETURNS RETURN PRIMARY KEY FOREIGN REFERENCES CONSTRAINT DEFAULT CHECK UNIQUE CASCADE IDENTITY \
		CASE WHEN THEN ELSE END WITH BEGIN TRAN TRANSACTION COMMIT ROLLBACK SAVE DECLARE EXEC EXECUTE GO USE IF WHILE BREAK CONTINUE \
		TRY CATCH THROW RAISERROR PRINT OFFSET FETCH NEXT ROWS ONLY OVER PARTITION PIVOT UNPIVOT NOLOCK GRANT REVOKE DENY \
		COLLATE NOCOUNT XACT_ABORT
		""".split(separator: " ").map(String.init)
		let functions = """
		COUNT COUNT_BIG SUM AVG MIN MAX STRING_AGG ISNULL COALESCE NULLIF IIF CHOOSE ABS CEILING FLOOR ROUND POWER SQRT \
		LEN DATALENGTH SUBSTRING CHARINDEX PATINDEX LEFT RIGHT UPPER LOWER LTRIM RTRIM TRIM REPLACE REPLICATE REVERSE STUFF \
		CONCAT CONCAT_WS FORMAT STR CAST CONVERT TRY_CAST TRY_CONVERT PARSE GETDATE GETUTCDATE SYSDATETIME SYSUTCDATETIME \
		SYSDATETIMEOFFSET DATEADD DATEDIFF DATEDIFF_BIG DATEPART DATENAME EOMONTH YEAR MONTH DAY NEWID NEWSEQUENTIALID \
		ROW_NUMBER RANK DENSE_RANK NTILE LAG LEAD FIRST_VALUE LAST_VALUE JSON_VALUE JSON_QUERY JSON_MODIFY ISJSON OPENJSON \
		OBJECT_ID OBJECT_NAME SCHEMA_NAME DB_NAME DB_ID SUSER_NAME USER_NAME SCOPE_IDENTITY IDENT_CURRENT @@ROWCOUNT @@IDENTITY \
		@@VERSION @@SPID @@TRANCOUNT
		""".split(separator: " ").map(String.init)
		let types = ["INT", "BIGINT", "SMALLINT", "TINYINT", "BIT", "DECIMAL", "NUMERIC", "MONEY", "SMALLMONEY", "FLOAT", "REAL",
		             "DATE", "TIME", "DATETIME", "DATETIME2", "SMALLDATETIME", "DATETIMEOFFSET", "CHAR", "VARCHAR", "NCHAR", "NVARCHAR",
		             "TEXT", "NTEXT", "BINARY", "VARBINARY", "IMAGE", "UNIQUEIDENTIFIER", "XML", "SQL_VARIANT", "MAX", "HIERARCHYID",
		             "GEOGRAPHY", "GEOMETRY", "ROWVERSION", "TIMESTAMP"]
		let any: [SQLKind: ServerVersion] = [.sqlserver: ServerVersion(0)]
		// 이름 따옴표는 " (QUOTED_IDENTIFIER 켜짐 — 로그인 때 ODBC 옵션). 앱이 만드는 SQL 은 [이름], 나누기는 […] 도 건너뛴다
		var s = SQLSyntax(identifierQuote: 0x22, stringQuotes: [0x27], backslashEscapes: false, hashComments: false, delimiterCommand: false,
		                  highlightKeywords: Set(keywords + types + ["COUNT", "SUM", "AVG", "MIN", "MAX"]), completionKeywords: keywords,
		                  functions: functions.map { SQLFunction(name: $0, since: any) },
		                  reservedWords: Set(keywords + types + ["USER", "KEY", "FILE", "PUBLIC", "RULE", "PLAN", "BROWSE", "OPEN", "CLOSE",
		                                                         "READ", "SYSTEM_USER", "CURRENT_USER", "SESSION_USER", "STATISTICS"]))
		s.tsqlBatches = true
		return s
	}()
}

/// T-SQL 글 나누기 도움
enum TSQLScript {
	/// ; 로 나누면 안 되는 글로 시작하는지: CREATE [OR ALTER] / ALTER 프로시저·함수·트리거·뷰, DECLARE (변수는 배치 안에서만 산다)
	static func startsBlock(_ s: String) -> Bool {
		let t = s.replacingOccurrences(of: #"(?s)/\*.*?\*/|--[^\n]*"#, with: " ", options: .regularExpression)
		let words = t.split(whereSeparator: { !($0.isLetter || $0 == "_") }).prefix(4).map { $0.uppercased() }
		guard let first = words.first else { return false }
		if first == "DECLARE" { return true }
		guard first == "CREATE" || first == "ALTER" else { return false }
		let objects: Set<String> = ["PROCEDURE", "PROC", "FUNCTION", "TRIGGER", "VIEW"]
		for w in words.dropFirst() {
			if objects.contains(w) { return true }
			if !["OR", "ALTER"].contains(w) { return false }
		}
		return false
	}

	/// 줄 전체가 GO (뒤에 횟수·공백 허용) 인지: u[i] 가 줄 첫 글자일 때 그 줄 끝 위치, 아니면 nil
	static func goLineEnd(_ u: [UInt16], at i: Int) -> Int? {
		var b = i - 1
		while b >= 0 && (u[b] == 32 || u[b] == 9) { b -= 1 }
		guard b < 0 || u[b] == 10 else { return nil }
		guard i + 1 < u.count, u[i] == 71 || u[i] == 103, u[i + 1] == 79 || u[i + 1] == 111 else { return nil }
		var j = i + 2
		while j < u.count && (u[j] == 32 || u[j] == 9 || u[j] == 13 || (u[j] >= 48 && u[j] <= 57)) { j += 1 }
		return j >= u.count || u[j] == 10 ? j : nil
	}

	/// GO 줄로 배치 나누기 (빈 배치는 뺀다)
	static func batches(_ sql: String) -> [String] {
		let u = Array(sql.utf16)
		var out: [String] = []
		var start = 0, i = 0
		var quote: UInt16 = 0
		func cut(_ end: Int) {
			let t = String(utf16CodeUnits: Array(u[start..<end]), count: end - start).trimmingCharacters(in: .whitespacesAndNewlines)
			if !t.isEmpty { out.append(t) }
		}
		while i < u.count {
			let c = u[i]
			if quote != 0 { if c == quote { quote = 0 }; i += 1; continue }
			switch c {
			case 39: quote = 39
			case 91: quote = 93          // [ … ]
			case 45 where i + 1 < u.count && u[i + 1] == 45:
				while i < u.count && u[i] != 10 { i += 1 }
				continue
			case 47 where i + 1 < u.count && u[i + 1] == 42:
				i += 2
				while i + 1 < u.count && !(u[i] == 42 && u[i + 1] == 47) { i += 1 }
				i += 2
				continue
			case 71, 103:
				if let end = goLineEnd(u, at: i) { cut(i); start = end; i = end; continue }
			default: break
			}
			i += 1
		}
		cut(u.count)
		return out
	}
}
