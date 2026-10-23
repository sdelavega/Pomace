# Translation glossary

Pomace uses neutral, concise macOS UI language. Spanish uses tú; French uses vous; German uses Sie. Japanese and Korean explanations use polite neutral language, with compact noun/action labels. Translate the user's task, not English idioms. A sweep means rechecking a watched folder and compressing eligible files; it never means deleting or cleaning files. A scan only inspects files.

| Concept | zh-Hans | es | ja | ko | de | fr | pt-BR |
|---|---|---|---|---|---|---|---|
| Compress / decompress | 压缩 / 解压缩 | comprimir / descomprimir | 圧縮 / 展開 | 압축 / 압축 해제 | komprimieren / dekomprimieren | compresser / décompresser | comprimir / descomprimir |
| Transparent compression | 透明压缩 | compresión transparente | 透過的な圧縮 | 투명 압축 | transparente Komprimierung | compression transparente | compressão transparente |
| Watched folder | 监视的文件夹 | carpeta supervisada | 監視対象フォルダ | 모니터링하는 폴더 | überwachter Ordner | dossier surveillé | pasta monitorada |
| Sweep | 重新检查并压缩 | revisión y compresión | 再確認と圧縮 | 재확인 및 압축 | Prüfen und Komprimieren | vérification et compression | revisão e compressão |
| Scan | 扫描 | analizar | スキャン | 스캔 | scannen | analyser | analisar |
| Exclusion / excluded | 排除 / 已排除 | exclusión / excluido | 除外 | 제외 | Ausschluss / ausgeschlossen | exclusion / exclu | exclusão / excluído |
| Reclaimed space | 释放的空间 | espacio recuperado | 節約した容量 | 확보한 공간 | eingesparter Speicherplatz | espace récupéré | espaço recuperado |
| Verify (data integrity) | 验证 | verificar | 検証 | 검증 | überprüfen | vérifier | verificar |
| Hard link | 硬链接 | enlace físico | ハードリンク | 하드 링크 | Hardlink | lien physique | link físico |
| Sparse file | 稀疏文件 | archivo disperso | スパースファイル | 희소 파일 | Sparse-Datei | fichier creux | arquivo esparso |
| Administrator | 管理员 | administrador | 管理者 | 관리자 | Administrator | administrateur | administrador |

Use short forms of “sweep” where the schedule context is clear (检查, revisión, 再確認, 재확인, Prüfung, passage, revisão). Do not call a sweep a cleanup. “Verification” in compression policy means checking the round trip, while a scheduled recheck inspects a folder again.

## macOS terminology

Checked against this machine's installed Apple localization resources, rather than translating English labels from memory: System Settings `Localizable.loctable`; the TranslationAPI, GeneralSettings, LoginItems, SecurityPrivacy, PowerPreferences and BatterySettingsIntents extensions under `/System/Library/ExtensionKit/Extensions`; and Finder `Localizable.strings`. The Login Items section is called “Login Items & Extensions” on newer macOS; retain the shorter destination name where the source refers to Login Items. Literal filesystem paths such as `/Applications` never change.

| Apple term | zh-Hans | es | ja | ko | de | fr | pt-BR |
|---|---|---|---|---|---|---|---|
| Settings | 设置 | Ajustes | 設定 | 설정 | Einstellungen | Réglages | Ajustes |
| System Settings | 系统设置 | Ajustes del Sistema | システム設定 | 시스템 설정 | Systemeinstellungen | Réglages Système | Ajustes do Sistema |
| General | 通用 | General | 一般 | 일반 | Allgemein | Général | Geral |
| Applications folder | 应用程序 | Aplicaciones | アプリケーション | 응용 프로그램 | Programme | Applications | Aplicativos |
| Login Items | 登录项 | Ítems de inicio | ログイン項目 | 로그인 항목 | Anmeldeobjekte | Ouverture | Itens de Início |
| Full Disk Access | 完全磁盘访问权限 | Acceso total al disco | フルディスクアクセス | 전체 디스크 접근 권한 | Festplattenvollzugriff | Accès complet au disque | Acesso Total ao Disco |
| Low Power Mode | 低电量模式 | Modo de bajo consumo | 低電力モード | 저전력 모드 | Stromsparmodus | Mode Économie d’énergie | Modo Pouca Energia |
| Finder | 访达 | Finder | Finder | Finder | Finder | Finder | Finder |
| Time Machine | 时间机器 | Time Machine | Time Machine | Time Machine | Time Machine | Time Machine | Time Machine |

Keep Pomace, applesauce, LZFSE, ZLIB, LZVN, APFS, HFS+, Homebrew and GitHub unchanged. Keep CLI flags, xattr, SQL and SQLite recognizable. Format tokens, including their positional indices and integer widths, are executable contracts. Reorder indexed placeholders as needed; preserve the order of unindexed placeholders.

Counts use CLDR cardinal categories: en/de one+other; es/fr/pt-BR one+many+other; zh-Hans/ja/ko other only. French and Brazilian Portuguese one includes zero. Use natural count-neutral wording in retained legacy nonplural count strings. A nested count phrase must fit its enclosing template without requiring case or gender changes.
