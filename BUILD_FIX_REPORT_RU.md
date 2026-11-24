# Исправление ошибки сборки Erosion (v23)

Исходный лог: `message.txt` от 2026-11-02.

## Найденная блокирующая ошибка

В исходном логе присутствовала одна строка `error:`:

`Erosion/FileManager/Browser/FileBrowserView.swift:745:16: the compiler is unable to type-check this expression in reasonable time`

Xcode завершил workflow с `(3 failures)`, но это каскадные build-task failures после единственной первичной ошибки компилятора.

## Исправление

- Удалён отдельный `.onChange(of: airlift.appScanRunning)` для Bundle Application.
- Оставлен единый observer `appScanRunning`.
- Логика Bundle/Application и PluginKitPlugin reload вынесена в `handleAppScanStateChange(running:)` вне длинной SwiftUI modifier chain.
- Это снижает сложность выражения `body` и исключает два независимых observer-а, которые могли одновременно инициировать обновление.

## Проверки

- В исходном логе найдено: 1 блокирующая ошибка `error:`.
- Swift-файлы приложения: 78.
- `swiftc -frontend -parse` прошёл для всех 78 Swift-файлов без ошибок.
- ZIP проверен на целостность.

## Предупреждения

В исходном логе также присутствуют предупреждения, включая предупреждения Swift 6 о захвате изменяемых переменных и вызовах MainActor-изолированных методов из не изолированных контекстов, устаревшие API и deprecated `onChange`. Проект собирается в режиме Swift 5 (`SWIFT_VERSION = 5.0`), поэтому эти записи не являлись причиной текущего падения. Они не массово переписывались: такое изменение затронуло бы concurrency-поведение многих независимых компонентов и не требуется для устранения указанной ошибки сборки.

Полный Xcode build после исправления в этой среде недоступен; проверка синтаксиса не является заменой полной сборки на macOS.
