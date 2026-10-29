IP CHECK - VPN, location and ISP lookup for Windows 11
======================================================

GETTING STARTED
1. Unzip the folder somewhere permanent, e.g. C:\Tools\IPCheck
2. Right-click the zip first > Properties > tick "Unblock" (stops SmartScreen nagging), then unzip.
3. Double-click "IP Check.bat".
   Tip: right-click "IP Check.bat" > Show more options > Send to > Desktop (create shortcut).

Nothing to install - it uses the PowerShell and .NET that ship with Windows 10/11.
It follows your Windows light/dark mode.

HOW TO USE
- IP address: paste the person's public IP (from sign-in logs, your VPN/RDP gateway,
  or have them visit a "what is my IP" site). You can paste a whole log line; it pulls the IP out.
- Where they say they are (optional): "City, State" or a 5-digit ZIP. The app measures the
  distance and flags anything beyond your limit (100 miles by default, change it in Settings).
- Employee / ticket (optional): saved with the lookup in history and the copied report.
- Copy report puts a plain-text summary on the clipboard for a ticket or email.
- History opens every lookup as a CSV (Excel).

RESULT COLOURS
- Green  : no VPN/proxy found, and within the distance limit
- Yellow : datacenter/hosting IP, Apple Private Relay, location mismatch, or VPN status unknown
- Red    : at least one source says VPN, proxy or Tor

DATA SOURCES (Settings)
Works out of the box with proxycheck.io (100 lookups/day without a key) and ipwho.is.
More sources = more reliable VPN detection. All of these have free sign-ups:

  proxycheck.io   free key -> 1,000/day          https://proxycheck.io
  vpnapi.io       free key -> 1,000/day          https://vpnapi.io
  IPQualityScore  free account, monthly limit    https://www.ipqualityscore.com
  ip-api.com      free endpoint is NON-COMMERCIAL only; for company use buy a Pro key
                  (off by default)               https://members.ip-api.com

Paste a key into Settings and that source turns on. Keys are encrypted with your Windows
account (DPAPI) - copying settings.json to another PC or user won't expose them.

GOOD TO KNOW
- IP geolocation is approximate (usually city level). It is never a street address.
  Mobile/cellular and satellite IPs can map hundreds of miles from the real location.
- No VPN database is complete. A "clean" result means no source recognised the IP,
  not a guarantee. Corporate VPNs, residential proxies and new VPN servers can slip through.
- A datacenter/hosting result with no VPN flag usually still means VPN, proxy or cloud desktop.

FILES (all in %APPDATA%\IPCheck)
  settings.json   your settings (keys encrypted)
  history.csv     lookup history (IPs, names you typed, results) - stays on this PC
  error.log       written only if something goes wrong

TROUBLESHOOTING
- Window doesn't appear: open PowerShell and run
    powershell -STA -ExecutionPolicy Bypass -File "C:\Tools\IPCheck\IPCheck.ps1"
  to see any error, or check %APPDATA%\IPCheck\error.log
- A source shows "limit reached": its daily quota is used up; add/upgrade that key.
- Company proxy/firewall: the app uses your Windows proxy settings; the hosts it needs are
  proxycheck.io, vpnapi.io, ipqualityscore.com, ip-api.com, ipwho.is, nominatim.openstreetmap.org
