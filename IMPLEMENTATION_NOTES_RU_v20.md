# Erosion v20 — App Decrypt / Airlift UI / Light Theme

База: `Erosion_AppsManagement_POSIX_v19.zip`.

## App Decrypt
- `Apps Management` переименован в `App Decrypt` в строке навигации и заголовке экрана.
- Удалён отдельный блок `Activity`; сообщения о Prepare/Decrypt отправляются через существующий `AirliftBridge.appendFeatureLog` в Home → Logs.
- Удалён пункт `Export` из long-press меню и соответствующий отдельный экспорт `.app` ZIP.
- Оставлены `Prepare` и `Decrypt`; Decrypt продолжает создавать IPA из подготовленного `.app` (не снимает FairPlay DRM).
- Удалена подсказка `Long-press…` под списком.
- Поиск перенесён в обычную строку List, поэтому скроллится вместе со списком, а не закреплён через `.searchable`.
- Placeholder иконки теперь состоит из одного серого скруглённого фона, без второго SF Symbol-квадрата.

## Общий интерфейс
- `File Operations` скрыт только в `isAirliftCompatibilityMode()`. Для остальных режимов оставлен.
- Убраны ссылки `Bundles` из File Browser.
- `Display not readable paths` показывается только при `airliftUIAccessRequired()`; настройка снова управляет показом соответствующих системных контейнеров.
- Удалена команда `Go to Path` из меню File Browser вместе с неиспользуемыми состояниями и экранами перехода.

## Airlift
- В `Actions` добавлена красная destructive-кнопка `Delete File` / `Delete Directory`, выбранная по `Object` и подтверждаемая отдельным диалогом.
- Удаление идёт через существующий `AirliftBridge.removeRemotePath`; события пишутся в Home → Logs. Запрещено удаление корня `/`.
- `View` и `Export` больше не содержат суффикс `File`/`Folder`.
- `Read File` и `Read Directory` сохраняют уточнение типа. В `Object` значение `Folder` переименовано в `Directory`.
- Статусы чтения, ошибки и сообщения снимка с `Folder` переименованы в `Directory`.
- Удалён footer под `Actions` про read snapshots.
- Для файлов/папок Airlift snapshot, если исходный remote root не относится к `/var/mobile`, `/var/tmp` или `/var/Managed Preferences/mobile`, в Info показываются `root:wheel`. Для перечисленных путей остаются полученные значения.

## Светлая тема
- `findmy_preview` инвертируется только в light appearance. Динамические маркеры и строки устройств рисуются отдельными слоями и не инвертируются.
- TCC: в light appearance инвертируются статичные тексты, кнопки и контур notification preview. Системный фон карточки уже динамически меняет цвет по appearance, поэтому сам фон не инвертируется повторно. Картинка разрешения / пользовательское изображение не затрагивается.

## Проверки
- Все Swift-файлы прошли `swiftc -frontend -parse`.
- `xcodebuild` в среде отсутствует; полная сборка приложения/IPA здесь не выполнялась.
