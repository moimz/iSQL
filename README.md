# iSQL

맥에서 쓰는 **MySQL / MariaDB 클라이언트**입니다.
서버의 모든 데이터베이스와 테이블을 사이드바 하나에 코멘트와 함께 보여 주고, 탭·쿼리 패널·구조 편집을 한 창에서 다룹니다.
원격 DB 는 SSH 터널로 접속하고, 비밀번호는 키체인에만 둡니다.

## 기능

**접속**
- 접속 정보와 SSH 터널(비밀번호 또는 키 파일)을 한 화면에서 입력, 접속 시험
- 비밀번호는 모두 iCloud 키체인(동기화 항목)에 저장, 서버 목록은 iCloud Drive 로 다른 맥과 동기화
- 서버 그룹, 끌어다 놓아 정리, 서버 색
- 제목바의 서버 메뉴로 여러 서버를 오가며, 서버마다 열어 둔 탭을 기억

**탐색**
- 사이드바에 모든 DB 의 테이블을 코멘트와 함께 (DB 머리는 위에 붙어 있음)
- 테이블 이름 · 코멘트 · 컬럼 이름 · 컬럼 코멘트 검색
- DB 개요: 테이블별 행 수 · 데이터/인덱스 크기 · 엔진 · 콜레이션 (phpMyAdmin 구조 화면처럼)

**데이터**
- 테이블마다 탭, 데이터 / 구조 보기 (⌘1 / ⌘2)
- 조건 줄로 WHERE 만들기(테이블마다 최근 10개 기억), 컬럼 제목으로 정렬 · 그 컬럼으로 찾기
- 페이지 나누기 (InnoDB 는 어림 행 수, 눌러서 `COUNT(*)`)
- 칸 고치기 · 행 추가 · 삭제를 모았다가 한 트랜잭션으로 저장 (SQL 미리보기)

**쿼리 패널** (⌘J)
- 서버마다 하나, 입력한 내용은 지우지 않고 남음
- 여러 문장 실행, 결과 탭, `LIMIT` 없는 SELECT 는 자동으로 나눠 받기
- WHERE 없는 UPDATE, DELETE, DROP, TRUNCATE, ALTER 는 실행 전에 확인

**구조**
- 테이블 정보 패널(⌥⌘I): 엔진 · 문자셋 · 콜레이션 · 코멘트 변경, 정확한 행 수와 크기, 인덱스 추가 / 삭제

**내보내기 · 복제**
- SQL 내보내기: 테이블, 고른 테이블들, DB 전체, 쿼리 결과 (구조 / DROP / 데이터 선택, 진행 창)
- 데이터베이스 복제: 원본과 같은 문자셋 · 콜레이션으로 새 DB 를 만들고 구조와 데이터를 옮김.
  데이터는 테이블마다 트랜잭션 하나 안에서 기본 키 순서로 5,000행씩 넣어 원본을 오래 잠그지 않음

## 요구 사항

- macOS 26 이상, Apple silicon(arm64)
- 빌드: Xcode 26 이상
- 서버: MySQL 5.7 / 8.x (`mysql_native_password`, `caching_sha2_password` 인증). MariaDB 는 같은 인증 방식이면 접속됩니다

외부 패키지는 없습니다. Apple 기본 프레임워크(SwiftUI, AppKit, CryptoKit, Security)만 씁니다.
MySQL 프로토콜은 직접 구현했고, SSH 터널은 macOS 에 들어 있는 `/usr/bin/ssh` 를 씁니다.

## 빌드

```bash
git clone https://github.com/moimz/iSQL.git
open iSQL/iSQL.xcodeproj
```

프로젝트는 moimz 팀(Developer ID, iCloud 컨테이너 `iCloud.com.moimz.iSQL`)으로 서명하도록 설정돼 있습니다.
직접 빌드하려면 타깃의 **Signing & Capabilities** 에서 팀과 번들 ID를 내 것으로 바꾸고,
iCloud 컨테이너와 키체인 접근 그룹도 내 것으로 바꾸거나 iCloud 기능을 빼세요.
iCloud 를 쓸 수 없으면 서버 목록은 이 맥에만, 비밀번호는 이 맥의 키체인에만 저장합니다.

샌드박스는 쓰지 않습니다 (`ssh` 를 띄워야 하므로).

## 데이터 위치

| 무엇 | 어디 |
|---|---|
| 서버 목록 (iCloud) | iCloud Drive 앱 전용 폴더 `iCloud.com.moimz.iSQL/Data/Servers/<UUID>.json`, `groups.json` |
| 서버 목록 (이 맥만) | `~/Library/Application Support/iSQL/Servers/<UUID>.json` |
| 비밀번호 | 키체인 (iCloud 키체인 동기화 항목, 안 되면 이 맥에만) |
| 열어 둔 탭, 쿼리 패널 내용, WHERE 기록 | 이 맥의 앱 설정 (UserDefaults) |

서버 하나가 JSON 파일 하나이고, 비밀번호는 파일에 들어가지 않습니다.

## 라이선스

[MIT](LICENSE)
