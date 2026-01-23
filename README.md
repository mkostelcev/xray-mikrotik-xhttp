# xray-mikrotik-xhttp

Docker-контейнер для MikroTik с Xray VLESS+Reality+xHTTP и tun2socks для прозрачного проксирования.

## Особенности

- **[Xray-core](https://github.com/XTLS/Xray-core)** с xHTTP транспортом — обходит DPI, который обрывает долгоживущие TCP соединения
- **VLESS + Reality** — маскировка под легитимный TLS трафик (github.com и др.)
- **[tun2socks](https://github.com/xjasonlyu/tun2socks)** — прозрачное проксирование TCP/UDP трафика
- **DoH (DNS over HTTPS)** — резолв VPN сервера через зашифрованный DNS, обход DNS hijacking
- **Multi-arch** — поддержка amd64, arm64, arm/v7 (MikroTik)
- **IP forwarding** — маршрутизация трафика от MikroTik через контейнер

## Требования

- MikroTik с RouterOS 7.x (ARM, ARM64 или x86)
- Минимум 256MB RAM (рекомендуется 512MB+)
- Внешний накопитель (USB/SD) или tmpfs для контейнера
- VPS с 3x-ui или standalone Xray
- Домен для маскировки (например, www.github.com)

### Совместимые модели MikroTik

| Модель | RAM | CPU | Рекомендация |
|--------|-----|-----|--------------|
| **RB5009UG+S+IN** | 1 GB | ARM64 1.4GHz 4-core | Отлично |
| **RB4011iGS+5HacQ2HnD** | 1 GB | ARM 1.4GHz 4-core | Отлично |
| **RB4011iGS+RM** | 1 GB | ARM 1.4GHz 4-core | Отлично |
| **CCR2004-16G-2S+** | 4 GB | ARM64 1.7GHz 4-core | Отлично |
| **CCR2116-12G-4S+** | 16 GB | ARM64 2.0GHz 16-core | Отлично |
| **hAP ax²** | 1 GB | ARM64 1.8GHz 4-core | Отлично |
| **hAP ax³** | 1 GB | ARM64 1.8GHz 4-core | Отлично |
| **RB3011UiAS-RM** | 1 GB | ARM 1.4GHz 2-core | Хорошо |
| **hEX S (RB760iGS)** | 256 MB | ARM 880MHz 2-core | Минимум |
| **hAP ac²** | 128 MB | ARM 716MHz 4-core | Не рекомендуется |
| **hAP ac lite** | 64 MB | - | Не поддерживается |

> **Примечание:** Для комфортной работы контейнера с xray+tun2socks рекомендуется минимум 512MB RAM. На устройствах с 256MB возможны проблемы при высокой нагрузке.

---

## Подготовка MikroTik

### 1. Установка пакета container

Скачайте extra packages для вашей версии RouterOS с [mikrotik.com/download](https://mikrotik.com/download).

```routeros
# Проверка архитектуры
/system resource print

# После загрузки .npk файла на роутер
/system reboot
```

### 2. Включение поддержки контейнеров

```routeros
# Включить container mode (требует перезагрузки)
/system/device-mode/update container=yes

# После перезагрузки проверить
/system/device-mode/print
```

### 3. Настройка RAM-хранилища (рекомендуется)

Использование tmpfs снижает износ USB/SD и ускоряет работу контейнера.

```routeros
# Создать tmpfs диск в RAM (64MB достаточно для контейнера)
/disk
add type=tmpfs tmpfs-max-size=64M slot=tmpfs1

# Проверить
/disk print
```

### 4. Настройка registry и хранилища

```routeros
# Настройка реестра с tmpfs для временных файлов
/container/config
set registry-url=https://ghcr.io tmpdir=tmpfs1/tmp

# Для хранения контейнера можно использовать:
# - disk1 (USB/SD) - если нужна персистентность после перезагрузки
# - tmpfs1 (RAM) - быстрее, но контейнер перекачивается после ребута
```

**Вариант A: USB/SD (персистентный)**
```routeros
# Контейнер сохраняется на диске
/container add ... root-dir=disk1/xray
```

**Вариант B: RAM (быстрый, без износа)**
```routeros
# Контейнер в RAM, перекачивается при каждом старте
/container add ... root-dir=tmpfs1/xray
```

> **Совет:** Для MikroTik с достаточным объёмом RAM (512MB+) рекомендуется tmpfs.

### 4. Настройка DNS для pull образа

```routeros
# Временно установить публичный DNS для скачивания образа
/ip dns set servers=8.8.8.8,1.1.1.1
```

---

## Быстрый старт

### 1. Настройка сервера (3x-ui)

Создайте inbound в 3x-ui:

| Параметр | Значение |
|----------|----------|
| Protocol | VLESS |
| Port | 443 |
| Security | Reality |
| Transport | xHTTP |
| Path | / |
| Dest | www.github.com:443 |
| SNI | www.github.com |

Сохраните полученные данные: UUID, Public Key, Short ID.

### 2. Настройка MikroTik

#### 2.1. Создание veth интерфейса

```routeros
/interface veth add address=172.18.20.6/30 gateway=172.18.20.5 name=veth-xray
/ip address add interface=veth-xray address=172.18.20.5/30
```

#### 2.2. Переменные окружения

```routeros
/container envs
add list=xray key=SERVER_ADDRESS value=your-server.com
add list=xray key=SERVER_PORT value=443
add list=xray key=ID value=your-uuid
add list=xray key=SNI value=www.github.com
add list=xray key=PBK value=your-public-key
add list=xray key=SID value=your-short-id
add list=xray key=SPX value=/
add list=xray key=FP value=firefox
```

#### 2.3. Создание контейнера

**С хранением на USB/SD (персистентный):**
```routeros
/container add remote-image=ghcr.io/mkostelcev/xray-mikrotik-xhttp:latest \
    interface=veth-xray envlist=xray root-dir=disk1/xray \
    start-on-boot=yes logging=yes
```

**С хранением в RAM (рекомендуется для 512MB+ RAM):**
```routeros
/container add remote-image=ghcr.io/mkostelcev/xray-mikrotik-xhttp:latest \
    interface=veth-xray envlist=xray root-dir=tmpfs1/xray \
    start-on-boot=yes logging=yes
```

> При использовании tmpfs образ скачивается заново после каждой перезагрузки роутера.

#### 2.4. NAT для трафика через контейнер

```routeros
/ip firewall nat add action=masquerade chain=srcnat out-interface=veth-xray comment="xray-masq"
```

#### 2.5. Запуск контейнера

```routeros
# Проверить статус (должен быть "stopped" после pull)
/container print

# Запустить контейнер
/container start [find tag~"xray"]

# Проверить что контейнер running
/container print
```

#### 2.6. Управление контейнером

```routeros
# Остановить
/container stop [find tag~"xray"]

# Перезапустить
/container stop [find tag~"xray"]
/container start [find tag~"xray"]

# Логи контейнера
/log print where topics~"container"

# Shell внутрь контейнера (для отладки)
/container shell [find tag~"xray"]

# Удалить контейнер (для пересоздания)
/container stop [find tag~"xray"]
/container remove [find tag~"xray"]
```

#### 2.7. Обновление контейнера

```routeros
# Остановить и удалить старый
/container stop [find tag~"xray"]
/container remove [find tag~"xray"]

# Скачать новый образ и создать контейнер
/container add remote-image=ghcr.io/mkostelcev/xray-mikrotik-xhttp:latest \
    interface=veth-xray envlist=xray root-dir=disk1/xray \
    start-on-boot=yes logging=yes

# Дождаться скачивания и запустить
/container start [find tag~"xray"]
```

---

## Маршрутизация с Failover

### Концепция "Anchor" маршрута

Для отказоустойчивости между двумя провайдерами используется "якорный" IP (8.8.4.4), через который резолвятся все остальные маршруты.

#### Anchor маршруты (обновляются через DHCP скрипты)

```routeros
/ip route
add dst-address=8.8.4.4/32 gateway=<gw-ether1> distance=1 scope=10 check-gateway=ping comment="anchor-ether1"
add dst-address=8.8.4.4/32 gateway=<gw-ether2> distance=2 scope=10 check-gateway=ping comment="anchor-ether2"
```

#### Маршрут к VPN серверу (recursive через anchor)

```routeros
/ip route add dst-address=147.45.50.47/32 gateway=8.8.4.4 target-scope=11 distance=1 comment="xray-server-dynamic"
```

#### Default route через VPN

```routeros
/ip route add dst-address=0.0.0.0/0 gateway=172.18.20.6 distance=1 comment="vpn-default"
```

#### Маршруты к DoH серверам (для DNS резолва контейнером)

Контейнер использует DoH серверы для резолва VPN сервера:

| Провайдер | Primary | Secondary |
|-----------|---------|-----------|
| Cloudflare | 1.1.1.1 | 1.0.0.1 |
| Google | 8.8.8.8 | 8.8.4.4 |
| Quad9 | 9.9.9.9 | 149.112.112.112 |
| AdGuard | - | 94.140.14.14 |

```routeros
/ip route
# Primary DoH servers
add dst-address=1.1.1.1/32 gateway=8.8.4.4 target-scope=11 distance=1 comment="doh-cloudflare"
add dst-address=9.9.9.9/32 gateway=8.8.4.4 target-scope=11 distance=1 comment="doh-quad9"
# Secondary DoH servers
add dst-address=1.0.0.1/32 gateway=8.8.4.4 target-scope=11 distance=1 comment="doh-cloudflare-2"
add dst-address=149.112.112.112/32 gateway=8.8.4.4 target-scope=11 distance=1 comment="doh-quad9-2"
add dst-address=94.140.14.14/32 gateway=8.8.4.4 target-scope=11 distance=1 comment="doh-adguard"
```

> **Примечание:** 8.8.8.8 и 8.8.4.4 используются как anchor, поэтому отдельные маршруты не нужны.

---

## Скрипты для автоматизации

### Автообновление маршрута к VPN серверу по DNS

```routeros
/system script add name=update-xray-route source={
    :local domain "your-server.com"
    :local newip [:resolve $domain]

    /ip route remove [find where comment="xray-server-dynamic"]
    /ip route add dst-address="$newip/32" gateway=8.8.4.4 target-scope=11 distance=1 comment="xray-server-dynamic"
    :log info "Set xray route: $newip"
}

/system scheduler add name=update-xray-route interval=5m on-event=update-xray-route start-time=startup
```

### Обновление anchor маршрутов при смене DHCP gateway

```routeros
/system script
add name=update-anchor-ether1 source={
    :global anchorGw1
    /ip route remove [find where comment="anchor-ether1"]
    /ip route add dst-address=8.8.4.4/32 gateway=$anchorGw1 distance=1 scope=10 check-gateway=ping comment="anchor-ether1"
    :log info "Anchor ether1: $anchorGw1"
}

add name=update-anchor-ether2 source={
    :global anchorGw2
    /ip route remove [find where comment="anchor-ether2"]
    /ip route add dst-address=8.8.4.4/32 gateway=$anchorGw2 distance=2 scope=10 check-gateway=ping comment="anchor-ether2"
    :log info "Anchor ether2: $anchorGw2"
}

/ip dhcp-client
set [find interface=ether1] script=":global anchorGw1 \$\"gateway-address\"; /system script run update-anchor-ether1"
set [find interface=ether2] script=":global anchorGw2 \$\"gateway-address\"; /system script run update-anchor-ether2"
```

---

## BGP с Antifilter

Для маршрутизации RU-трафика напрямую через провайдера, а остального через VPN.

### BGP Community List

```routeros
/routing filter community-list
add communities=65444:900,65445:643 list=ru-direct name=ru-communities
```

### BGP Filter

```routeros
/routing filter rule
add chain=bgp-in rule="if (bgp-communities equal-list ru-direct) { set gw 8.8.4.4; set gw-check ping; set distance 1; accept }"
add chain=bgp-in rule="reject"
```

### Применение к BGP connection

```routeros
/routing bgp connection set [find] input.filter=bgp-in
```

**Логика:**
- Трафик к IP из списка antifilter (RU) → через провайдера
- Весь остальной трафик → через VPN контейнер

---

## Переменные окружения

| Переменная | Обязательна | По умолчанию | Описание |
|------------|-------------|--------------|----------|
| SERVER_ADDRESS | Да | - | Адрес Xray сервера (IP или домен) |
| SERVER_IP | Нет | - | IP сервера (переопределяет DNS резолв) |
| SERVER_PORT | Нет | 443 | Порт Xray сервера |
| ID | Да | - | VLESS UUID |
| SNI | Да | - | TLS SNI для маскировки |
| PBK | Да | - | Reality public key |
| SID | Да | - | Reality short ID |
| SPX | Нет | / | xHTTP path и spiderX |
| FP | Нет | firefox | TLS fingerprint (chrome, firefox, safari, edge) |
| ENCRYPTION | Нет | none | VLESS encryption |
| LOG_LEVEL | Нет | warning | Уровень логов (debug, info, warning, error) |

### Если DNS заблокирован

Укажите IP сервера напрямую:

```routeros
/container envs add list=xray key=SERVER_IP value=147.45.50.47
```

---

## Сборка

### Локальная сборка для ARM (MikroTik)

```bash
docker buildx build --platform linux/arm/v7 -t xray-mikrotik-xhttp:latest .
```

### Сборка с конкретными версиями

```bash
docker buildx build \
  --build-arg XRAY_VERSION=v26.1.18 \
  --build-arg TUN2SOCKS_VERSION=v2.6.0 \
  --platform linux/arm/v7 \
  -t xray-mikrotik-xhttp:latest .
```

---

## Диагностика

### Проверка работы контейнера

```routeros
/container shell [find name~"xray"]
```

```bash
# Проверка DNS
curl http://ifconfig.me --connect-timeout 10

# Таблица маршрутов
route

# Проверка процессов
ps aux
```

### Логи контейнера

```routeros
/container/log print where container~"xray"
```

### Проверка маршрутов на MikroTik

```routeros
/ip route print where gateway=172.18.20.6
/ip route print where comment~"anchor"
```

### Трафик через контейнер

```routeros
/tool torch interface=veth-xray
```

---

## Известные ограничения

- **ICMP (ping) не работает** — SOCKS5 поддерживает только TCP/UDP
- **Scope/target-scope** — для recursive routing в RouterOS 7 требуется `scope=10` на anchor и `target-scope=11` на зависимых маршрутах
- **Баг RouterOS** — переменные в `/ip route find where comment=$var` не работают корректно, используйте строковые литералы

---

## Архитектура

```
┌─────────────────────────────────────────────────────────────┐
│                        MikroTik                             │
│                                                             │
│  ┌─────────────┐     ┌──────────────────────────────────┐  │
│  │   Клиенты   │────▶│         Routing Table            │  │
│  └─────────────┘     │                                  │  │
│                      │  RU (BGP) ──▶ ether1/ether2      │  │
│                      │  Other ────▶ veth-xray           │  │
│                      └──────────────────────────────────┘  │
│                                    │                        │
│                                    ▼                        │
│                      ┌──────────────────────────────────┐  │
│                      │     Container (xray-mikrotik)    │  │
│                      │                                  │  │
│                      │  ┌────────┐    ┌─────────────┐  │  │
│                      │  │  xray  │───▶│  tun2socks  │  │  │
│                      │  │ SOCKS  │    │    tun0     │  │  │
│                      │  └────────┘    └─────────────┘  │  │
│                      └──────────────────────────────────┘  │
│                                    │                        │
└────────────────────────────────────│────────────────────────┘
                                     │ VLESS+Reality+xHTTP
                                     ▼
                          ┌─────────────────────┐
                          │    VPS (3x-ui)      │
                          │    Xray Server      │
                          └─────────────────────┘
```

---

## License

MIT
