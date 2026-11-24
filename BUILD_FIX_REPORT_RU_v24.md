# Erosion v24 — Build Fix Report

## Основание

Проверен предоставленный GitHub Actions / Xcode build log (`message.txt`). В нём найдено ровно одно сообщение уровня `error:`:

`Erosion/FileManager/Browser/FileBrowserView.swift:749:19: the compiler is unable to type-check this expression in reasonable time`

Остальные 105 сообщений `warning:` не являются блокирующими ошибками этой сборки. Часть предупреждений помечена Xcode как потенциальные ошибки при включении Swift 6 language mode; проект в этом build настроен на Swift 5.0.

## Исправление

В `FileBrowserView.swift`:

- Вынесены обработчики состояния и уведомлений из длинной цепочки модификаторов основного `List`.
- Добавлен отдельный `FileBrowserLifecycleModifier`.
- События маршрутизируются через один `handleBrowserLifecycleEvent(_:)`, а не через большое число inline closures в `body`.
- Сохранены прежние реакции на сортировку, обновление списка, изменения InstallationProxy/AFC-метаданных, завершение AFC probe, завершение app scan и событие готовности `/usr/libexec`.
- Логика fallback для PluginKitPlugin вынесена в отдельный метод `handlePluginKitPluginProbeStateChange(running:)`.

Остальные файлы проекта не менялись относительно v23.

## Проверки в этой среде

- `swiftc -frontend -parse`: 89 из 89 Swift-файлов прошли проверку синтаксиса.
- ZIP integrity: проверка `unzip -t`.

## Ограничение

Полный `xcodebuild` здесь недоступен (среда Linux, без iOS SDK/Xcode). Поэтому устранение именно type-checker blocker подтверждено структурным рефакторингом и синтаксической проверкой, но зелёная Xcode-сборка пока не заявляется. Предупреждения Swift 6 намеренно не переписывались массово: это отдельная задача миграции concurrency и API.
