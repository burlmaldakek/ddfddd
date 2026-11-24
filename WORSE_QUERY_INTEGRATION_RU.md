# Worse Query в Erosion mod

В эту версию перенесена оригинальная связка Worse Query из исходного Erosion:

- `Exploits/WorseQuerySwift.swift` — `WorseQuery`, `wq`, получение App Group из entitlement и `grantAccess(path:)`.
- `Exploits/worse_query.m` / `Exploits/worse_query.h` — оригинальная реализация Objective-C.
- `Erosion/Erosion.entitlements` использует исходный идентификатор `group.com.jbdotparty.Erosion.WQ`.
- `ErosionApp` записывает выбранную App Group в Home → Logs (`(wq) Using app group: ...`).

File Browser использует ту же схему, что и оригинал: корневые списки контейнеров перечисляются через существующий `bad_query_list`; для App Groups / System Containers и при входе в UUID-каталог вызывается `wq.grantAccess(path:)`. MobileGestalt, Config Tweaks и File Operations также запрашивают доступ через `wq.grantAccess(path:)`.

Код и UI Airlift не переносились и не переписывались.
