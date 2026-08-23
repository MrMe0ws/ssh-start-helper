# ssh-start-helper

Интерактивный скрипт базовой настройки **Ubuntu 24.04+** VDS: обновление системы, безопасная смена SSH-порта, UFW с аудитом существующих правил, hardening и опциональный [distillium/motd](https://github.com/distillium/motd).

## Быстрый запуск

Одна команда — **установка и сразу запуск** настройки (root):

```bash
curl -fsSL https://raw.githubusercontent.com/MrMe0ws/ssh-start-helper/v1.0.5/install.sh | bash
```

> **Важно:** URL с `/main/` может отдавать старую версию из кэша GitHub CDN.
> Используйте `/v1.0.5/` (тег релиза) или добавьте `?$(date +%s)` к `/main/`.

Альтернатива (последний main, с обходом кэша):

```bash
curl -fsSL "https://raw.githubusercontent.com/MrMe0ws/ssh-start-helper/main/install.sh?$(date +%s)" | bash
```

Только установить, без запуска wizard:

```bash
SSH_HELPER_NO_RUN=1 curl -fsSL https://raw.githubusercontent.com/MrMe0ws/ssh-start-helper/v1.0.5/install.sh | bash
```

**Повторный запуск** настройки:

```bash
ssh-start-helper
```

Проверка без изменений:

```bash
ssh-start-helper --dry-run
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

Тесты (на Ubuntu):

```bash
sudo bash tests/smoke-test.sh
```

## Требования

- Ubuntu 24.04+ (Debian тоже может работать)
- Root-доступ
- Открытая SSH-сессия
- Интернет (для apt и MOTD)

## Команды

| Команда | Описание |
|---------|----------|
| `ssh-start-helper` | Интерактивная настройка VDS |
| `ssh-start-helper --dry-run` | Просмотр без изменений |
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

1. Открывает новый порт в UFW
2. Пишет `/etc/ssh/sshd_config.d/99-ssh-start-helper.conf`
3. Проверяет `sshd -t`
4. Перезагружает SSH
5. Ждёт подтверждения нового подключения
6. Только после этого предлагает закрыть порт 22

**Не закрывайте текущую SSH-сессию** до проверки!

## Файлы на сервере

| Путь | Назначение |
|------|------------|
| `/opt/ssh-start-helper/` | Установленные скрипты |
| `/usr/local/bin/ssh-start-helper` | Команда запуска |
| `/opt/ssh-start-helper/state.env` | Состояние настройки |
| `/opt/ssh-start-helper/backup/` | Бэкапы конфигов |
| `/var/log/ssh-start-helper.log` | Лог (без ANSI) |
| `/etc/ssh/sshd_config.d/99-ssh-start-helper.conf` | SSH drop-in |

## Откат SSH

```bash
rm /etc/ssh/sshd_config.d/99-ssh-start-helper.conf
systemctl reload ssh
ls /opt/ssh-start-helper/backup/
```

## MOTD

После установки этапа MOTD:

- `motd` — показать приветствие
- `motd-set` — интерактивные настройки

Рекомендуется ставить MOTD **после** SSH и UFW.

## Лицензия

MIT
