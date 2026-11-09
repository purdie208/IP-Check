# IP Check

A Windows 11 desktop tool for IT staff that checks a public IP address for **VPN / proxy use**, shows its **approximate location** and **ISP**, and, if you enter where the person says they are, how far that is from the IP's location.

It's built for checking that remote staff and new hires are connecting from roughly where they say they are, without a VPN.

- Native Windows UI that follows your light / dark mode
- Nothing to install: runs on the PowerShell 5.1 and .NET that ship with Windows 10/11
- Asks several IP-intelligence services at once and combines their answers
- One-click reports in plain text or **Discord format**

## Features

| Area | What you get |
|---|---|
| **VPN detection** | VPN, proxy, Tor, Apple iCloud Private Relay and datacenter/hosting flags, with the VPN provider's name when known (e.g. NordVPN) and a risk score |
| **Location** | City, region, country, postal code and coordinates, plus a Map button (OpenStreetMap). Shows whether the sources agree |
| **Distance check** | Enter "City, State" or a ZIP and the IP is flagged if it's beyond your mile limit (default 100) |
| **ISP** | ISP, organization, ASN and connection type (residential, business, wireless, hosting) |
| **Overall result** | Green = clean, yellow = datacenter / Private Relay / location mismatch / unknown, red = VPN, proxy or Tor detected |
| **Reports** | *Copy report* (plain text for tickets/email) and *Copy for Discord* (bold labels, status emoji, map link) |
| **History** | Every lookup saved to a local CSV that opens in Excel |

## Getting started

1. Download the repo (**Code → Download ZIP**) or clone it.
2. If you downloaded the ZIP: right-click it → **Properties** → tick **Unblock** → OK, then extract it.
3. Double-click **`IP Check.bat`**.

To launch it from PowerShell instead:

```powershell
powershell -STA -ExecutionPolicy Bypass -File .\IPCheck.ps1
# optionally pre-fill an IP:
powershell -STA -ExecutionPolicy Bypass -File .\IPCheck.ps1 -Ip 203.0.113.45
```

## Usage

1. **IP address:** paste the person's public IP. A whole log line works too; the IP is pulled out of it.
2. **Where they say they are** (optional): `City, State` or a 5-digit ZIP.
3. **Employee / ticket** (optional): stored in history and included in reports.
4. Press **Check IP** (or Enter).
5. Use **Copy for Discord** or **Copy report** to share the result.

Example Discord output:

```
### 🟢 No VPN or proxy detected
**IP:** `203.0.113.45`
**VPN / proxy:** ✅ No (3 sources)
**Datacenter:** ✅ No
**Location:** 📍 [Kirkland, Washington, US](<map link>)
**Stated location:** Kirkland, WA → ≈2 mi away ✅
**ISP:** Example ISP (AS64500) · Residential
-# Sources: IPQualityScore ✅ · proxycheck.io ✅ · vpnapi.io ✅ · ipwho.is (location only)
-# 47.68, -122.2 · approximate, city level · limit 100 mi · checked 2026-11-09 08:00
```

## Data sources

Works right away with **proxycheck.io** (no key) and **ipwho.is**. Add free API keys in **Settings** for more reliable detection: a source turns on as soon as you paste its key.

| Service | Used for | Free tier |
|---|---|---|
| [proxycheck.io](https://proxycheck.io) | VPN / proxy / Tor, location, ISP | 100/day without a key, 1,000/day with a free key |
| [vpnapi.io](https://vpnapi.io) | VPN / proxy / Tor / Private Relay | 1,000/day with a free key |
| [IPQualityScore](https://www.ipqualityscore.com) | VPN / proxy / Tor, fraud score | Monthly allowance with a free account |
| [ip-api.com](https://ip-api.com) | Proxy and hosting flags, location, ISP | Free endpoint is **non-commercial only**; use a Pro key for business use (off by default) |
| [ipwho.is](https://ipwhois.io) | Second opinion on location and ISP | 1,000/day, no key |
| [Nominatim (OpenStreetMap)](https://nominatim.org) | Turns the stated location into coordinates | Free, light use |

API keys are encrypted with Windows DPAPI for the current user, so they can't be read from another account or PC.

## Files and privacy

Everything is stored locally in `%APPDATA%\IPCheck`:

| File | Contents |
|---|---|
| `settings.json` | Settings and encrypted API keys |
| `history.csv` | Lookup history (IPs, names/tickets you entered, results) |
| `error.log` | Only written if something goes wrong |

Nothing is stored in the app folder, so the repo never picks up keys or history. Lookups send only the IP address (and the stated location, for geocoding) to the services above.

## Limitations

- **Location is approximate.** IP geolocation is city level at best and never a street address. Mobile, cellular and satellite IPs can map hundreds of miles from the user.
- **No VPN database is complete.** A clean result means no source recognized the IP, not a guarantee. A datacenter result with no VPN flag usually still means a VPN, proxy or cloud desktop.
- Use a red or yellow result as a reason to follow up, not as proof on its own.

## Troubleshooting

- **Window doesn't open:** run the PowerShell command above to see the error, or check `%APPDATA%\IPCheck\error.log`.
- **A source says "limit reached":** its daily quota is used up. Add or upgrade that key.
- **Behind a company proxy/firewall:** allow `proxycheck.io`, `vpnapi.io`, `ipqualityscore.com`, `ip-api.com`, `ipwho.is` and `nominatim.openstreetmap.org`.

## Requirements

Windows 10 or 11 with Windows PowerShell 5.1 (built in). Internet access to the services above.

See [CHANGELOG.md](CHANGELOG.md) for version history.
