# Изменения Erosion — 18.10.2026

## 1. Просмотрщик медиа
- Масштаб и размеры изображения центрированы по горизонтали, вертикальное положение не менялось.
- Убраны кнопка Resize и связанный с ней код изменения/записи размеров.
- MOV/видео preview теперь предварительно загружает AVURLAsset, проверяет доступность воспроизведения, показывает понятную ошибку при неудаче и запускает подготовленный AVPlayer.

## 2. Airlift и Tweaks
- Airlift перенесён из Tweaks в отдельную секцию Experimental файлового браузера.
- Секция с Custom Passcode и Cards Override осталась в Tweaks на прежнем месте; заголовок изменён на Airlift, значок — `antenna.radiowaves.left.and.right`.
- Механизмы самого Airlift и реализации Custom Passcode / Cards Override не переписывались.

## 3. Airlift → Containers
- Переключатель Applications / Daemons / Plugins / AppGroups находится в одной секции с Search и Results.
- Вертикальные отступы переключателя немного увеличены.

## 4. File Browser
- System Paths удалён как отдельная секция. В Other Paths добавлены виртуальные папки System и Usr.
- System показывает реальные директории /System/Developer, /System/Cryptexes и /System/Library; Usr — реальные /usr/lib и /usr/share. Доступ к ним остаётся read-only и идёт через прежний FileBrowserView.
- Etc и другие существующие пути сохранены.
- Подпись изменена на `Other stuff. Read-only.`; в Go to Path удалён пример-плейсхолдер, текущий путь остаётся заполненным в поле.

## 5. Dialer Themer → Get Current Keys
- В режиме Airlift путь MobilePhone-контейнера разрешается через уже встроенный InstallationProxy.
- Папка `/var/mobile/Containers/Data/Application/<UUID>/Library/Caches/TelephonyUI-10/` читается существующим Airlift folder-snapshot механизмом с проверкой результата восстановления контейнера.
- Из полученного ZIP импортируются найденные файлы TelephonyUI-10 в Dialer Themer. Обычный локальный путь чтения не менялся.

## Проверка
- Успешно выполнен синтаксический разбор всех 70 Swift-файлов проекта.
- Полная сборка Xcode в этой среде не запускалась.

## 6. Patch v7 — File Browser / Airlift
- SQLite preview now validates the SQLite 3 header and stages the local/Airlift snapshot in the app cache before opening it read-only. It also copies present `-wal`/`-shm` sidecars and reports whether the snapshot is missing, unreadable, incomplete, or unsupported instead of only showing the generic `unable to open database file` error.
- Replaced the `.car` Quick Look-only panel with an asset catalog browser. It dynamically queries CoreUI `CUICatalog` for image names, supports search, renders a selected image when the OS runtime supports it, and exports that rendered asset as PNG. The original `.car` file can still be shared/exported. Since the reader uses a private runtime interface, compatibility depends on the iOS build; it falls back to a readable error if the class/selectors are unavailable.
- Airlift's toolbar now groups controls into one trailing row: the ellipsis menu is on the left; Pair (or the existing Airlift note button when already paired) is on the right.
- Added `Export Pairing` in the Airlift ellipsis menu. It copies the current non-empty canonical pairing file resolved by `PairingController.pairingFilePath()` to a temporary export file and opens the iOS share sheet; the temporary copy is deleted when the share sheet closes.
- Restored the former Read-only section icon (`lock.shield`) instead of the eye.
- Reordered the first four Read-only entries as Developer, System, Usr, Etc. The main File Browser labels remain `Usr` / `Etc`, while the destination navigation titles are now `usr` / `etc`.

## Validation for v7
- All Swift files passed `swiftc -frontend -parse` after these edits.
- No Xcode/iOS SDK is available in this environment, so a full iOS type-check/build and on-device tests were not performed. In particular, the `.car` CoreUI reader must be tested on the target iOS build, and SQLite preview needs an on-device test against the same Airlift snapshot that failed previously.


## v9 hotfix: remove DB/SQLite and .car viewers
- Removed the custom SQLite/DB preview and its SQLite3 dependency.
- Removed the custom CoreUI `.car` catalog preview and Objective-C runtime dependency.
- `.db`, `.sqlite`, `.sqlite3`, and `.car` now use the existing generic Quick Look fallback; existing image/video/audio/binary previews remain unchanged.
- Kept the Airlift workflow change that skips Rust/AirliftFFI rebuild unless relevant Rust sources changed or manual force-rebuild is requested.
