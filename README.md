# YSTCore Rust Server Kurulum

Tek dosya ile **Windows** veya **Linux (Ubuntu/Debian)** üzerine Rust Dedicated Server kurar.
Hiçbir şey sormaz; tüm ayarlar `server_config.json` dosyasından okunur.

Her şey resmi kaynaklardan iner:

| Bileşen | Kaynak |
|---|---|
| SteamCMD | Valve CDN (`steamcdn-a.akamaihd.net`). Windows'ta Valve imzası doğrulanır. |
| Rust Dedicated Server | SteamCMD, app `258550` ([Facepunch wiki](https://wiki.facepunch.com/rust/Creating-a-server)) |
| Oxide (isteğe bağlı) | [umod.org](https://umod.org/games/rust) üzerinden OxideMod resmi sürümü |
| Carbon (isteğe bağlı) | [carbonmod.gg](https://carbonmod.gg/owners/getting-started) üzerinden `production_build` |

## Windows

1. Repoyu indir (Code → Download ZIP ya da `git clone`).
2. `server_config.json` dosyasını düzenle.
3. **`kurulum.bat`** dosyasına çift tıkla.
   - Güvenlik duvarı kurallarının da eklenmesi için: sağ tık → **Yönetici olarak çalıştır**.

Kurulum bittiğinde aynı klasörde şunlar oluşur:

```
steamcmd\            SteamCMD
rustserver\          Rust Dedicated Server (+ Oxide/Carbon)
logs\                Sunucu logları
.kurulum\state.json  Otomatik üretilen seed ve RCON şifresi
start_server.bat     Sunucuyu başlatır (çökerse otomatik yeniden başlatır)
update_server.bat    Günceller (kurulumu tekrar çalıştırır)
```

## Linux (Ubuntu / Debian)

Tek satır (repo yoksa indirir, varsa günceller, sonra kurar):

```bash
curl -fsSL https://raw.githubusercontent.com/Mtemizce/RustServer/main/install.sh | sudo bash
```

Ayarları önceden düzenlemek istersen:

```bash
git clone https://github.com/Mtemizce/RustServer.git && cd RustServer
nano server_config.json
sudo ./install.sh
```

- Gerekli paketleri (`lib32gcc-s1`, `jq`, `curl`, `unzip`) kendisi kurar.
- systemd varsa `ystcore-rust-<identity>` servisini oluşturur. Bu servis açılışta otomatik başlar ve çökerse kendini yeniden başlatır.
  - Log izleme: `journalctl -u ystcore-rust-ystcore -f`
  - Yönetim: `sudo systemctl start|stop|restart ystcore-rust-ystcore`
- `ufw` aktifse gerekli portları açar.
- Güncellemek için `sudo ./update_server.sh` ya da `sudo ./install.sh` çalıştır.

## server_config.json

| Alan | Açıklama | Varsayılan |
|---|---|---|
| `server.hostname` | Sunucu listesinde görünen ad | `YSTCore Rust Life` |
| `server.description` | Bağlanırken görünen açıklama (`\n` ile satır atlanır) | |
| `server.url` / `headerImage` / `logoImage` | Web sitesi, banner görseli, logo | boş |
| `server.tags` | Sunucu listesi etiketleri, ör. `monthly,vanilla` | boş |
| `server.identity` | Kayıtların tutulduğu klasörün adı (harf, rakam, `-`, `_`). Değiştirirsen yeni bir dünya başlar. | `ystcore` |
| `server.maxPlayers` | Kapasite | `50` |
| `server.level` | Harita tipi | `Procedural Map` |
| `server.worldSize` | Harita boyutu (1000–6000) | `3500` |
| `server.seed` | Harita seed'i. `0` verilirse rastgele üretilir ve kalıcı olarak saklanır. | `0` |
| `server.saveInterval` | Otomatik kayıt aralığı (saniye) | `300` |
| `server.pve` | PvE modu | `false` |
| `network.ip` | Dinlenecek IP | `0.0.0.0` |
| `network.gamePort` | Oyun portu (UDP) | `28015` |
| `network.queryPort` | Sunucu listesi portu (UDP) | `28017` |
| `network.appPort` | Rust+ portu (TCP) | `28082` |
| `rcon.password` | RCON şifresi. Boş bırakılırsa güçlü bir şifre üretilir ve `.kurulum/state.json` içine yazılır. | boş |
| `rcon.ip` | RCON'un dinleyeceği IP. `127.0.0.1` olursa sadece aynı makineden erişilir (önerilen). | `127.0.0.1` |
| `rcon.port` | RCON portu (TCP) | `28016` |
| `rcon.web` | WebSocket RCON | `true` |
| `mods.framework` | `none`, `oxide` veya `carbon` | `none` |
| `steam.branch` | `public`, `staging`, `aux01`… | `public` |
| `runtime.autoRestart` | Çökünce yeniden başlat | `true` |
| `runtime.openFirewall` | Güvenlik duvarı portlarını aç (Windows'ta yönetici gerekir) | `true` |
| `runtime.startAfterInstall` | Kurulumdan sonra sunucuyu başlat | `true` |
| `runtime.linuxSystemdService` | Linux'ta systemd servisi oluştur | `true` |
| `runtime.linuxServiceUser` | Linux'ta sunucuyu çalıştıracak kullanıcı. Yoksa oluşturulur. Boş bırakılırsa sudo'yu çağıran kullanıcı kullanılır. | boş |
| `extraConvars` | `server.cfg` dosyasına eklenecek ek ayarlar | `{}` |

`extraConvars` örneği:

```json
"extraConvars": {
  "decay.scale": 0.5,
  "server.radiation": true,
  "chat.serverlog": true
}
```

> `server.cfg` her kurulumda yeniden üretilir. Kalıcı değişiklikleri `server_config.json` içinde yap.

## Notlar

- **Mod değiştirme:**
  - `oxide`'dan `none`'a geçince SteamCMD'nin `validate` adımı orijinal dosyaları geri yükler.
  - `carbon`'dan `none`'a geçince Carbon'un yükleyicisi devre dışı bırakılır.
- **RCON güvenliği:** RCON şifreleme kullanmaz (`ws://`). Dışarıya açmak yerine aynı makinedeki bir ajan üzerinden yönetilmesi önerilir.
- **Steam indirme hataları:** SteamCMD ilk çalıştırmada kendini güncelleyip çıkar (çıkış kodu 7). Steam'in indirme sunucuları da ara sıra zaman aşımı verir. Betik bu durumlarda 5 kez yeniden dener.
