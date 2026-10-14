# ssh-start-helper

Интерактивный скрипт базовой настройки Linux VDS (**Ubuntu 22.04 / 24.04**, Debian 12, RHEL-семейство): обновление системы, безопасная смена SSH-порта, UFW с аудитом существующих правил, hardening и опциональный [distillium/motd](https://github.com/distillium/motd).

## Быстрый запуск

Одна команда — **установка и сразу запуск** настройки (root):

```bash
curl -fsSL https://raw.githubusercontent.com/MrMe0ws/ssh-start-helper/v1.1.0/install.sh | bash
```

> **Важно:** URL с `/main/` может отдавать старую версию из кэша GitHub CDN.
> Используйте `/v1.1.0/` (тег релиза) или добавьте `?$(date +%s)` к `/main/`.

Альтернатива (последний main, с обходом кэша):

```bash
curl -fsSL "https://raw.githubusercontent.com/MrMe0ws/ssh-start-helper/main/install.sh?$(date +%s)" | bash
```

Только установить, без запуска wizard:

```bash
SSH_HELPER_NO_RUN=1 curl -fsSL https://raw.githubusercontent.com/MrMe0ws/ssh-start-helper/v1.1.0/install.sh | bash
```

**Повторный запуск** настройки:

```bash
ssh-start-helper
```

Проверка без изменений:

```bash
ssh-start-helper --dry-run
```

Если whiptail криво рисуется в вашем терминале — текстовые меню:

```bash
ssh-start-helper --text
```

Повторный запуск в любой момент — скрипт идемпотентен и не трогает UFW-правила без подтверждения.

## Локальная разработка

```bash
git clone https://github.com/MrMe0ws/ssh-start-helper.git
cd ssh-start-helper
sudo bash install.sh          # установка + сразу wizard
sudo ssh-start-helper         # повторный запуск
sudo bash run.sh --dry-run    # dry-run без установки в /opt
```

Тесты:

```bash
sudo bash tests/smoke-test.sh                 # синтаксис, версии, загрузка модулей
for img in ubuntu:22.04 ubuntu:24.04 debian:12; do   # модули на разных ОС (в одноразовом контейнере)
    docker run --rm -v "$PWD":/src:ro "$img" bash /src/tests/distro-test.sh
done
```

## Требования

- Ubuntu 22.04 / 24.04 (проверено), Debian 12; Rocky/Alma/CentOS Stream — best effort (dnf + firewalld + SELinux)
- Root-доступ
- Открытая SSH-сессия
- Интернет (для пакетов и MOTD). `ping` не нужен — сеть проверяется по HTTPS/TCP

## Команды

| Команда | Описание |
|---------|----------|
| `ssh-start-helper` | Интерактивная настройка VDS |
| `ssh-start-helper --dry-run` | Просмотр без изменений |
| `ssh-start-helper --text` | Текстовые меню вместо whiptail |
| `ssh-start-helper --version` | Версия |
| `ssh-start-helper --help` | Справка |

## Что делает скрипт

| Этап | Описание |
|------|----------|
| Обновление | `apt update && upgrade` |
| Hostname / timezone | Опциональная смена |
| Sudo-пользователь | Создание user + SSH-ключ (интерактивно) |
| SSH | Смена порта, hardening через drop-in конфиг |
| UFW | Аудит существующих правил на prod-VDS |
| fail2ban | Защита SSH от брутфорса |
| unattended-upgrades | Авто security-патчи |
| Swap | 1 GB при малой RAM |
| MOTD | Установка [distillium/motd](https://github.com/distillium/motd) |

## UFW на уже настроенном сервере

Если UFW уже **active** и открыты порты под проекты, скрипт:

1. Показывает таблицу всех правил
2. Спрашивает режим:
   - **Только добавить SSH-порт** (рекомендуется для prod)
   - **Просмотреть каждое правило**
   - **Не менять правила**

Скрипт **не выполняет** `ufw reset` и **не удаляет** правила без явного подтверждения.

## Безопасная смена SSH-порта

1. Бэкап `/etc/ssh` в `/opt/ssh-start-helper/backup/`
2. Открывает новый порт в firewall (UFW / firewalld) и в SELinux, если он включён
3. Пишет `/etc/ssh/sshd_config.d/00-ssh-start-helper.conf` — `00-`, потому что sshd берёт **первое**
   значение директивы (иначе `50-cloud-init.conf` перекрывает настройки). `Include` переносится в начало
   `sshd_config`, если стоит не там; на OpenSSH < 8.2 настройки пишутся блоком в начало `sshd_config`
4. Комментирует чужие строки `Port` (они суммируются — иначе sshd продолжит слушать 22)
5. Проверяет `sshd -t` и фактическую конфигурацию через `sshd -T`
6. Ubuntu 22.10+: отключает `ssh.socket` (он держит порт 22 и игнорирует `Port`)
7. Перезапускает SSH и проверяет SSH-баннер на новом порту
8. Ждёт подтверждения нового подключения. **Страховка:** если не подтвердить за 10 минут
   (например, оборвалась сессия) — автоматический откат к прежней конфигурации
9. Обновляет порт в jail fail2ban и предлагает закрыть 22 в firewall

**Не закрывайте текущую SSH-сессию** до проверки!

## fail2ban

Jail пишется в `/etc/fail2ban/jail.d/zz-ssh-start-helper.local` и перезаписывается при каждом запуске
(в т.ч. автоматически после смены SSH-порта — иначе баны блокируют старый порт):

- порт = фактический порт sshd, 5 попыток за 10 минут → бан на 1 час, повторным — дольше (до недели)
- `backend = systemd`, если нет `/var/log/auth.log` (Ubuntu 24.04 / Debian 12 без rsyslog)
- banaction подбирается под firewalld / iptables / nftables
- по желанию — ваш статический IP в whitelist

## Файлы на сервере

| Путь | Назначение |
|------|------------|
| `/opt/ssh-start-helper/` | Установленные скрипты |
| `/usr/local/bin/ssh-start-helper` | Команда запуска |
| `/opt/ssh-start-helper/state.env` | Состояние настройки |
| `/opt/ssh-start-helper/backup/` | Бэкапы конфигов |
| `/var/log/ssh-start-helper.log` | Лог (без ANSI) |
| `/etc/ssh/sshd_config.d/00-ssh-start-helper.conf` | SSH drop-in |
| `/etc/fail2ban/jail.d/zz-ssh-start-helper.local` | fail2ban jail |

## Откат SSH

```bash
ls /opt/ssh-start-helper/backup/                       # бэкапы /etc/ssh
cp -a /opt/ssh-start-helper/backup/etc_ssh-<дата>/. /etc/ssh/
rm /etc/ssh/sshd_config.d/00-ssh-start-helper.conf     # если его не было в бэкапе
systemctl restart ssh
```

## MOTD

После установки этапа MOTD:

- `motd` — показать приветствие
- `motd-set` — интерактивные настройки

Рекомендуется ставить MOTD **после** SSH и UFW.

## Лицензия

MIT
