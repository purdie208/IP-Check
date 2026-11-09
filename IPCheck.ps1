<#
    IP Check - VPN detection, approximate geolocation and ISP lookup for Windows 11.

    Runs on the Windows PowerShell 5.1 + WPF that ship with Windows 10/11. No installs needed.
    Launch with "IP Check.bat" (or: powershell -STA -ExecutionPolicy Bypass -File IPCheck.ps1)

    Data sources (each optional, configured in Settings):
      proxycheck.io   - VPN / proxy / Tor detection, location, ISP   (100/day without a key, 1,000/day with a free key)
      vpnapi.io       - VPN / proxy / Tor / Private Relay detection  (free key required)
      IPQualityScore  - VPN / proxy / Tor detection, fraud score     (key required)
      ip-api.com      - proxy + datacenter flags, location, ISP      (free endpoint is non-commercial only; Pro key for business)
      ipwho.is        - second opinion on location and ISP           (no key, 1,000/day)
      OpenStreetMap Nominatim - turns "where they say they are" into coordinates for the distance check

    Settings, encrypted API keys and lookup history are kept in %APPDATA%\IPCheck
#>
param([string]$Ip)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$script:AppDir       = Join-Path $env:APPDATA 'IPCheck'
$script:SettingsPath = Join-Path $script:AppDir 'settings.json'
$script:HistoryPath  = Join-Path $script:AppDir 'history.csv'
$script:ErrorLog     = Join-Path $script:AppDir 'error.log'
$script:Inv          = [Globalization.CultureInfo]::InvariantCulture
$script:Dash         = [string][char]0x2014
$script:Dot          = [string][char]0x25CF

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

function Write-ErrorLog([string]$Text) {
    try {
        if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }
        Add-Content -Path $script:ErrorLog -Value ("[{0}] {1}" -f (Get-Date -Format 's'), $Text)
    } catch {}
}

function Show-Fatal($Err) {
    $msg = "$Err"
    if ($Err -is [System.Management.Automation.ErrorRecord]) { $msg = "$($Err.Exception.Message)`r`n`r`n$($Err.ScriptStackTrace)" }
    Write-ErrorLog $msg
    [void][System.Windows.MessageBox]::Show("Something went wrong:`r`n`r`n$msg", 'IP Check', 'OK', 'Error')
}

try {
    Add-Type -Namespace IPCheckNative -Name Dwm -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int attrValue, int attrSize);
'@
} catch {}

# ---------------------------------------------------------------------------------------------
# Theme (follows Windows light / dark app mode)
# ---------------------------------------------------------------------------------------------
function Get-Theme {
    $light = $true
    try {
        $v = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        $light = ([int]$v.AppsUseLightTheme -eq 1)
    } catch {}
    if ($light) {
        return @{
            Dark = $false
            BG = '#F3F3F3'; CARD = '#FFFFFF'; BORDER = '#E5E5E5'; BORDERHOVER = '#C4C4C4'; DIVIDER = '#EDEDED'
            TEXT = '#1B1B1B'; SUB = '#5C5C5C'; MUTED = '#8A8A8A'
            INPUT = '#FFFFFF'; INPUTBORDER = '#D1D1D1'; SUBTLE = '#FBFBFB'; SUBTLEHOVER = '#F2F2F2'
            ACCENT = '#005FB8'; ACCENTTEXT = '#FFFFFF'
            GOOD = '#0F7B0F'; GOODBG = '#DFF6DD'; GOODBORDER = '#B9E3B5'
            WARN = '#9D5D00'; WARNBG = '#FFF4CE'; WARNBORDER = '#F1DB9A'
            BAD  = '#C42B1C'; BADBG  = '#FDE7E9'; BADBORDER  = '#F3C1C5'
        }
    }
    return @{
        Dark = $true
        BG = '#202020'; CARD = '#2B2B2B'; BORDER = '#383838'; BORDERHOVER = '#4F4F4F'; DIVIDER = '#353535'
        TEXT = '#FFFFFF'; SUB = '#C9C9C9'; MUTED = '#9D9D9D'
        INPUT = '#1E1E1E'; INPUTBORDER = '#464646'; SUBTLE = '#2F2F2F'; SUBTLEHOVER = '#3A3A3A'
        ACCENT = '#60CDFF'; ACCENTTEXT = '#000000'
        GOOD = '#6CCB5F'; GOODBG = '#283825'; GOODBORDER = '#3B5636'
        WARN = '#FCE100'; WARNBG = '#3B351B'; WARNBORDER = '#5E5426'
        BAD  = '#FF99A4'; BADBG  = '#432627'; BADBORDER  = '#6A3A3C'
    }
}

$script:Theme = Get-Theme
$script:Br = @{}
foreach ($k in @($script:Theme.Keys)) {
    if ($k -eq 'Dark') { continue }
    $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($script:Theme[$k]))
    $b.Freeze()
    $script:Br[$k] = $b
}

function T([double]$l, [double]$t, [double]$r, [double]$b) { New-Object Windows.Thickness($l, $t, $r, $b) }

# ---------------------------------------------------------------------------------------------
# XAML
# ---------------------------------------------------------------------------------------------
$SharedResources = @'
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{{CARD}}"/>
      <Setter Property="BorderBrush" Value="{{BORDER}}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="20"/>
    </Style>
    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Foreground" Value="{{SUB}}"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="SectionTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Glyph" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Field" TargetType="TextBox">
      <Setter Property="Foreground" Value="{{TEXT}}"/>
      <Setter Property="CaretBrush" Value="{{TEXT}}"/>
      <Setter Property="SelectionBrush" Value="{{ACCENT}}"/>
      <Setter Property="Background" Value="{{INPUT}}"/>
      <Setter Property="BorderBrush" Value="{{INPUTBORDER}}"/>
      <Setter Property="Padding" Value="10,0,10,0"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="5">
              <Grid>
                <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center" Focusable="False"/>
                <TextBlock x:Name="Ph" Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" Foreground="{{MUTED}}"
                           Margin="13,0,10,0" VerticalAlignment="Center" IsHitTestVisible="False" Visibility="Collapsed"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="Text" Value="">
                <Setter TargetName="Ph" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{{BORDERHOVER}}"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{{ACCENT}}"/>
                <Setter TargetName="Bd" Property="BorderThickness" Value="1,1,1,2"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PwField" TargetType="PasswordBox">
      <Setter Property="Foreground" Value="{{TEXT}}"/>
      <Setter Property="CaretBrush" Value="{{TEXT}}"/>
      <Setter Property="SelectionBrush" Value="{{ACCENT}}"/>
      <Setter Property="Background" Value="{{INPUT}}"/>
      <Setter Property="BorderBrush" Value="{{INPUTBORDER}}"/>
      <Setter Property="Padding" Value="10,0,10,0"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="5">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center" Focusable="False"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{{BORDERHOVER}}"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{{ACCENT}}"/>
                <Setter TargetName="Bd" Property="BorderThickness" Value="1,1,1,2"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="AccentButton" TargetType="Button">
      <Setter Property="Foreground" Value="{{ACCENTTEXT}}"/>
      <Setter Property="Background" Value="{{ACCENT}}"/>
      <Setter Property="Padding" Value="22,0,22,0"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.9"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.75"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SubtleButton" TargetType="Button">
      <Setter Property="Foreground" Value="{{TEXT}}"/>
      <Setter Property="Background" Value="{{SUBTLE}}"/>
      <Setter Property="BorderBrush" Value="{{BORDER}}"/>
      <Setter Property="Padding" Value="14,0,14,0"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="5" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{{SUBTLEHOVER}}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.8"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{{TEXT}}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Box" Width="18" Height="18" CornerRadius="4" BorderThickness="1" BorderBrush="{{INPUTBORDER}}" Background="{{INPUT}}" VerticalAlignment="Center">
                <TextBlock x:Name="Mark" Text="&#xE73E;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="12" Foreground="{{ACCENTTEXT}}"
                           HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="{{ACCENT}}"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="{{ACCENT}}"/>
                <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Hyperlink">
      <Setter Property="Foreground" Value="{{ACCENT}}"/>
      <Setter Property="TextDecorations" Value="{x:Null}"/>
    </Style>
'@

$MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="IP Check" Width="1080" Height="880" MinWidth="880" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="{{BG}}" Foreground="{{TEXT}}"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14" UseLayoutRounding="True">
  <Window.Resources>
__SHARED__
  </Window.Resources>
  <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <StackPanel Margin="32,24,32,28">

      <!-- Header -->
      <Grid Margin="0,0,0,20">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border Width="44" Height="44" CornerRadius="10" Background="{{ACCENT}}" Margin="0,0,14,0">
          <TextBlock Style="{StaticResource Glyph}" Text="&#xE774;" FontSize="22" Foreground="{{ACCENTTEXT}}" HorizontalAlignment="Center"/>
        </Border>
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <TextBlock Text="IP Check" FontFamily="Segoe UI Variable Display, Segoe UI" FontSize="26" FontWeight="SemiBold"/>
          <TextBlock Text="VPN detection, approximate location and ISP for any public IP address" Foreground="{{SUB}}"/>
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnHistory" Style="{StaticResource SubtleButton}" Margin="0,0,8,0" ToolTip="Open the lookup history (CSV)">
            <StackPanel Orientation="Horizontal">
              <TextBlock Style="{StaticResource Glyph}" Text="&#xE81C;" FontSize="14" Margin="0,0,8,0"/>
              <TextBlock Text="History"/>
            </StackPanel>
          </Button>
          <Button x:Name="BtnSettings" Style="{StaticResource SubtleButton}" ToolTip="Data sources, API keys and thresholds">
            <StackPanel Orientation="Horizontal">
              <TextBlock Style="{StaticResource Glyph}" Text="&#xE713;" FontSize="14" Margin="0,0,8,0"/>
              <TextBlock Text="Settings"/>
            </StackPanel>
          </Button>
        </StackPanel>
      </Grid>

      <!-- Input -->
      <Border Style="{StaticResource Card}" Margin="0,0,0,16">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="2*"/>
            <ColumnDefinition Width="16"/>
            <ColumnDefinition Width="2.2*"/>
            <ColumnDefinition Width="16"/>
            <ColumnDefinition Width="1.6*"/>
            <ColumnDefinition Width="16"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0">
            <TextBlock Style="{StaticResource FieldLabel}" Text="IP address"/>
            <TextBox x:Name="TxtIp" Style="{StaticResource Field}" Tag="e.g. 203.0.113.45" FontFamily="Cascadia Mono, Consolas, Segoe UI"/>
          </StackPanel>
          <StackPanel Grid.Column="2">
            <TextBlock Style="{StaticResource FieldLabel}" Text="Where they say they are (optional)"/>
            <TextBox x:Name="TxtExpected" Style="{StaticResource Field}" Tag="City, State  or  ZIP code"/>
          </StackPanel>
          <StackPanel Grid.Column="4">
            <TextBlock Style="{StaticResource FieldLabel}" Text="Employee / ticket (optional)"/>
            <TextBox x:Name="TxtNote" Style="{StaticResource Field}" Tag="Name or ticket #"/>
          </StackPanel>
          <Button x:Name="BtnCheck" Grid.Column="6" Style="{StaticResource AccentButton}" IsDefault="True" VerticalAlignment="Bottom">
            <StackPanel Orientation="Horizontal">
              <TextBlock Style="{StaticResource Glyph}" Text="&#xE721;" FontSize="14" Margin="0,0,8,0" Foreground="{{ACCENTTEXT}}"/>
              <TextBlock Text="Check IP"/>
            </StackPanel>
          </Button>
        </Grid>
      </Border>

      <!-- Verdict -->
      <Border x:Name="VerdictCard" CornerRadius="8" Padding="20,18,20,18" BorderThickness="1" Background="{{CARD}}" BorderBrush="{{BORDER}}">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="VerdictIcon" Style="{StaticResource Glyph}" Text="&#xE721;" FontSize="30" Margin="0,2,18,0" VerticalAlignment="Top" Foreground="{{SUB}}"/>
          <StackPanel Grid.Column="1">
            <TextBlock x:Name="VerdictTitle" FontSize="20" FontWeight="SemiBold" Text="Ready"/>
            <TextBlock x:Name="VerdictDetail" TextWrapping="Wrap" Margin="0,4,0,0" Foreground="{{SUB}}"
                       Text="Enter an IP address and press Check IP. Add where the person says they are to get a distance check."/>
          </StackPanel>
        </Grid>
      </Border>
      <ProgressBar x:Name="Busy" IsIndeterminate="True" Height="3" Margin="8,0,8,13" Visibility="Hidden"
                   Foreground="{{ACCENT}}" Background="Transparent" BorderThickness="0"/>

      <!-- Detail cards -->
      <Grid Margin="0,0,0,16">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="16"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="16"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Border Grid.Column="0" Style="{StaticResource Card}">
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <TextBlock Style="{StaticResource Glyph}" Text="&#xEA18;" FontSize="16" Foreground="{{ACCENT}}" Margin="0,0,10,0"/>
              <TextBlock Style="{StaticResource SectionTitle}" Text="Connection"/>
            </StackPanel>
            <StackPanel x:Name="PanelConn" Margin="0,14,0,0"/>
          </StackPanel>
        </Border>
        <Border Grid.Column="2" Style="{StaticResource Card}">
          <StackPanel>
            <Grid>
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Glyph}" Text="&#xE707;" FontSize="16" Foreground="{{ACCENT}}" Margin="0,0,10,0"/>
                <TextBlock Style="{StaticResource SectionTitle}" Text="Location"/>
              </StackPanel>
              <Button x:Name="BtnMap" Style="{StaticResource SubtleButton}" Height="28" Padding="10,0,10,0" FontSize="12.5"
                      HorizontalAlignment="Right" Visibility="Collapsed" ToolTip="Open the approximate location in OpenStreetMap">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Style="{StaticResource Glyph}" Text="&#xE8A7;" FontSize="12" Margin="0,0,6,0"/>
                  <TextBlock Text="Map"/>
                </StackPanel>
              </Button>
            </Grid>
            <StackPanel x:Name="PanelLoc" Margin="0,14,0,0"/>
          </StackPanel>
        </Border>
        <Border Grid.Column="4" Style="{StaticResource Card}">
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <TextBlock Style="{StaticResource Glyph}" Text="&#xE968;" FontSize="16" Foreground="{{ACCENT}}" Margin="0,0,10,0"/>
              <TextBlock Style="{StaticResource SectionTitle}" Text="Network / ISP"/>
            </StackPanel>
            <StackPanel x:Name="PanelNet" Margin="0,14,0,0"/>
          </StackPanel>
        </Border>
      </Grid>

      <!-- Per-source results -->
      <Border Style="{StaticResource Card}">
        <StackPanel>
          <TextBlock Style="{StaticResource SectionTitle}" Text="Results by source"/>
          <TextBlock Foreground="{{MUTED}}" FontSize="12.5" TextWrapping="Wrap" Margin="0,3,0,12"
                     Text="Each service keeps its own database, so they won't always agree. A VPN hit from any one source is worth a follow-up."/>
          <StackPanel x:Name="SourcesPanel"/>
        </StackPanel>
      </Border>

      <!-- Footer -->
      <Grid Margin="0,16,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="TxtStatus" Foreground="{{MUTED}}" FontSize="12.5" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,16,0"/>
        <StackPanel Grid.Column="1" Orientation="Horizontal">
          <Button x:Name="BtnCopy" Style="{StaticResource SubtleButton}" IsEnabled="False" Margin="0,0,8,0" ToolTip="Copy a plain-text summary for a ticket or email">
            <StackPanel Orientation="Horizontal">
              <TextBlock Style="{StaticResource Glyph}" Text="&#xE8C8;" FontSize="14" Margin="0,0,8,0"/>
              <TextBlock Text="Copy report"/>
            </StackPanel>
          </Button>
          <Button x:Name="BtnDiscord" Style="{StaticResource AccentButton}" Height="34" Padding="16,0,16,0" IsEnabled="False" ToolTip="Copy a formatted summary to paste into a Discord message">
            <StackPanel Orientation="Horizontal">
              <TextBlock Style="{StaticResource Glyph}" Text="&#xE8BD;" FontSize="14" Margin="0,0,8,0" Foreground="{{ACCENTTEXT}}"/>
              <TextBlock Text="Copy for Discord"/>
            </StackPanel>
          </Button>
        </StackPanel>
      </Grid>
    </StackPanel>
  </ScrollViewer>
</Window>
'@

$SettingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="IP Check - Settings" Width="600" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" Background="{{BG}}" Foreground="{{TEXT}}"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14" UseLayoutRounding="True">
  <Window.Resources>
__SHARED__
    <Style x:Key="Desc" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Foreground" Value="{{SUB}}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="28,3,0,8"/>
    </Style>
    <Style x:Key="Group" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{{SUB}}"/>
      <Setter Property="Margin" Value="0,18,0,8"/>
    </Style>
  </Window.Resources>
  <StackPanel Margin="28,22,28,24">
    <TextBlock Text="Settings" FontFamily="Segoe UI Variable Display, Segoe UI" FontSize="22" FontWeight="SemiBold"/>
    <TextBlock Style="{StaticResource Desc}" Margin="0,4,0,0"
               Text="Keys are optional but add sources and raise daily limits. They are encrypted for your Windows account and stored in %APPDATA%\IPCheck."/>

    <TextBlock Style="{StaticResource Group}" Text="VPN / PROXY DETECTION"/>
    <Border Style="{StaticResource Card}" Padding="18,14,18,14">
      <StackPanel>
        <CheckBox x:Name="ChkPc" Content="proxycheck.io"/>
        <TextBlock Style="{StaticResource Desc}">Works without a key (100 lookups/day). A free key raises it to 1,000/day. <Hyperlink x:Name="LnkPc" NavigateUri="https://proxycheck.io/">Get a key</Hyperlink></TextBlock>
        <PasswordBox x:Name="PwPc" Style="{StaticResource PwField}" Margin="28,0,0,14"/>

        <CheckBox x:Name="ChkVa" Content="vpnapi.io"/>
        <TextBlock Style="{StaticResource Desc}">Needs a free key (1,000 lookups/day). Also detects Tor and Apple iCloud Private Relay. <Hyperlink x:Name="LnkVa" NavigateUri="https://vpnapi.io/">Get a key</Hyperlink></TextBlock>
        <PasswordBox x:Name="PwVa" Style="{StaticResource PwField}" Margin="28,0,0,14"/>

        <CheckBox x:Name="ChkIq" Content="IPQualityScore"/>
        <TextBlock Style="{StaticResource Desc}">Needs a key (free accounts get a monthly allowance). Adds a fraud/risk score. <Hyperlink x:Name="LnkIq" NavigateUri="https://www.ipqualityscore.com/">Get a key</Hyperlink></TextBlock>
        <PasswordBox x:Name="PwIq" Style="{StaticResource PwField}" Margin="28,0,0,14"/>

        <CheckBox x:Name="ChkIa" Content="ip-api.com"/>
        <TextBlock Style="{StaticResource Desc}">The free endpoint is for non-commercial use only. For company use, enter a Pro key; with no key the free endpoint is used. <Hyperlink x:Name="LnkIa" NavigateUri="https://members.ip-api.com/">Pro plans</Hyperlink></TextBlock>
        <PasswordBox x:Name="PwIa" Style="{StaticResource PwField}" Margin="28,0,0,0"/>
      </StackPanel>
    </Border>

    <TextBlock Style="{StaticResource Group}" Text="LOCATION"/>
    <Border Style="{StaticResource Card}" Padding="18,14,18,14">
      <StackPanel>
        <CheckBox x:Name="ChkIw" Content="ipwho.is (second opinion on location and ISP)"/>
        <TextBlock Style="{StaticResource Desc}" Text="No key needed, 1,000 lookups/day, commercial use allowed. Does not do VPN detection on the free tier."/>
        <Grid Margin="0,6,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="110"/>
          </Grid.ColumnDefinitions>
          <TextBlock Text="Flag a location mismatch when the IP is more than this many miles away" TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,16,0"/>
          <TextBox x:Name="TxtMiles" Grid.Column="1" Style="{StaticResource Field}" Tag="100"/>
        </Grid>
      </StackPanel>
    </Border>

    <TextBlock Style="{StaticResource Group}" Text="HISTORY"/>
    <Border Style="{StaticResource Card}" Padding="18,14,18,14">
      <StackPanel>
        <CheckBox x:Name="ChkHist" Content="Save each lookup to a local history file (CSV)"/>
        <TextBlock Style="{StaticResource Desc}" Margin="28,3,0,0" Text="Stored in %APPDATA%\IPCheck\history.csv on this PC only. Opens in Excel from the History button."/>
      </StackPanel>
    </Border>

    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0">
      <Button x:Name="BtnCancel" Style="{StaticResource SubtleButton}" Content="Cancel" Width="100" Height="36" Margin="0,0,8,0" IsCancel="True"/>
      <Button x:Name="BtnSave" Style="{StaticResource AccentButton}" Content="Save" Width="100" IsDefault="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@

function Expand-Xaml([string]$Xaml) {
    $x = $Xaml.Replace('__SHARED__', $SharedResources)
    foreach ($k in $script:Theme.Keys) {
        if ($k -eq 'Dark') { continue }
        $x = $x.Replace('{{' + $k + '}}', $script:Theme[$k])
    }
    return $x
}

function New-XamlWindow([string]$Xaml) {
    return [Windows.Markup.XamlReader]::Parse((Expand-Xaml $Xaml))
}

function Set-WindowChrome($Window) {
    # Dark/light title bar and caption colour that matches the window background (Windows 11).
    $Window.Add_SourceInitialized({
        param($sender, $e)
        try {
            $h = (New-Object Windows.Interop.WindowInteropHelper($sender)).Handle
            $dark = [int]$script:Theme.Dark
            [void][IPCheckNative.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$dark, 4)
            $c = [Windows.Media.ColorConverter]::ConvertFromString($script:Theme.BG)
            $cref = [int]$c.R -bor ([int]$c.G -shl 8) -bor ([int]$c.B -shl 16)
            [void][IPCheckNative.Dwm]::DwmSetWindowAttribute($h, 35, [ref]$cref, 4)
        } catch {}
    })
}

function New-AppIcon {
    try {
        $dv = New-Object Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $dc.DrawRoundedRectangle($script:Br.ACCENT, $null, (New-Object Windows.Rect(0, 0, 64, 64)), 14, 14)
        $tf = New-Object Windows.Media.Typeface('Segoe Fluent Icons')
        $ft = New-Object Windows.Media.FormattedText([string][char]0xE774, $script:Inv, [Windows.FlowDirection]::LeftToRight, $tf, 38.0, $script:Br.ACCENTTEXT, 1.0)
        $dc.DrawText($ft, (New-Object Windows.Point(((64 - $ft.Width) / 2), ((64 - $ft.Height) / 2))))
        $dc.Close()
        $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap(64, 64, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($dv)
        $bmp.Freeze()
        return $bmp
    } catch { return $null }
}

# ---------------------------------------------------------------------------------------------
# Settings (API keys encrypted with DPAPI for the current Windows user)
# ---------------------------------------------------------------------------------------------
function Protect-Text([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return '' }
    return (ConvertTo-SecureString -String $s -AsPlainText -Force | ConvertFrom-SecureString)
}
function Unprotect-Text([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return '' }
    try {
        $ss = ConvertTo-SecureString -String $s
        $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
    } catch { return '' }
}

$script:KeyFields = @('ProxycheckKey', 'VpnapiKey', 'IpqsKey', 'IpApiKey')

function Get-DefaultSettings {
    return @{
        UseProxycheck = $true;  ProxycheckKey = ''
        UseVpnapi     = $true;  VpnapiKey     = ''
        UseIpqs       = $true;  IpqsKey       = ''
        UseIpApi      = $false; IpApiKey      = ''
        UseIpwho      = $true
        MilesThreshold = 100
        SaveHistory   = $true
    }
}

function Read-Settings {
    $s = Get-DefaultSettings
    $script:FirstRun = $true
    if (Test-Path $script:SettingsPath) {
        $script:FirstRun = $false
        try {
            $j = Get-Content -Path $script:SettingsPath -Raw | ConvertFrom-Json
            foreach ($k in @($s.Keys)) {
                $p = $j.PSObject.Properties[$k]
                if ($null -eq $p) { continue }
                if ($script:KeyFields -contains $k) { $s[$k] = Unprotect-Text ([string]$p.Value) }
                elseif ($k -eq 'MilesThreshold') { $s[$k] = [int]$p.Value }
                else { $s[$k] = [bool]$p.Value }
            }
        } catch { Write-ErrorLog "Could not read settings: $($_.Exception.Message)" }
    }
    return $s
}

function Save-Settings($s) {
    if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }
    $o = [ordered]@{}
    foreach ($k in ($s.Keys | Sort-Object)) {
        if ($script:KeyFields -contains $k) { $o[$k] = Protect-Text ([string]$s[$k]) } else { $o[$k] = $s[$k] }
    }
    ($o | ConvertTo-Json) | Set-Content -Path $script:SettingsPath -Encoding UTF8
}

function Get-EnabledSources {
    $s = $script:Settings
    $list = New-Object System.Collections.ArrayList
    if ($s.UseProxycheck) { [void]$list.Add(@{ Name = 'proxycheck.io'; Key = $s.ProxycheckKey }) }
    if ($s.UseVpnapi -and $s.VpnapiKey) { [void]$list.Add(@{ Name = 'vpnapi.io'; Key = $s.VpnapiKey }) }
    if ($s.UseIpqs -and $s.IpqsKey) { [void]$list.Add(@{ Name = 'IPQualityScore'; Key = $s.IpqsKey }) }
    if ($s.UseIpApi) { [void]$list.Add(@{ Name = 'ip-api.com'; Key = $s.IpApiKey }) }
    if ($s.UseIpwho) { [void]$list.Add(@{ Name = 'ipwho.is'; Key = '' }) }
    return , $list
}

# ---------------------------------------------------------------------------------------------
# Lookup worker - runs in a background runspace, one instance per source
# ---------------------------------------------------------------------------------------------
$WorkerScript = {
    param([string]$Name, [string]$Ip, [string]$Key, [string]$Query)

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $UA  = 'IPCheck/1.0 (Windows desktop; internal IT verification tool)'
    $inv = [Globalization.CultureInfo]::InvariantCulture

    function Get-Json([string]$Url) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15 -UserAgent $UA -Headers @{ Accept = 'application/json' }
            $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
            return ($text | ConvertFrom-Json)
        } catch {
            $ex = $_.Exception
            if ($ex -is [System.Net.WebException] -and $null -ne $ex.Response) {
                $code = [int]$ex.Response.StatusCode
                $msg = $null
                try {
                    $sr = New-Object IO.StreamReader($ex.Response.GetResponseStream())
                    $body = $sr.ReadToEnd(); $sr.Close()
                    $j = $body | ConvertFrom-Json
                    if ($j.message) { $msg = [string]$j.message } elseif ($j.error) { $msg = [string]$j.error }
                } catch {}
                if (-not $msg) { $msg = "HTTP $code" }
                if ($code -eq 429) { $msg = "Daily or rate limit reached ($msg)" }
                elseif ($code -eq 401 -or $code -eq 403) { $msg = "Key rejected or access denied ($msg)" }
                throw $msg
            }
            if ($ex -is [System.Net.WebException] -and "$($ex.Status)" -eq 'Timeout') { throw 'Timed out' }
            throw $ex.Message
        }
    }
    function D($v) {
        if ($null -eq $v -or "$v" -eq '') { return $null }
        $d = 0.0
        if ([double]::TryParse([string]$v, [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { return $d }
        return $null
    }
    function S($v) {
        if ($null -eq $v) { return $null }
        $s = ([string]$v).Trim()
        if ($s -eq '' -or $s -eq 'Unknown' -or $s -eq 'N/A') { return $null }
        return $s
    }
    function YN($v) {
        if ($null -eq $v) { return $null }
        if ($v -is [bool]) { return $v }
        $s = ([string]$v).Trim().ToLowerInvariant()
        if ($s -eq 'yes' -or $s -eq 'true' -or $s -eq '1') { return $true }
        if ($s -eq 'no' -or $s -eq 'false' -or $s -eq '0') { return $false }
        return $null
    }
    function Any([object[]]$vals) {
        $sawFalse = $false
        foreach ($v in $vals) { if ($v -eq $true) { return $true } elseif ($v -eq $false) { $sawFalse = $true } }
        if ($sawFalse) { return $false }
        return $null
    }

    $R = @{
        Source = $Name; Ok = $false; Error = $null; Note = $null; HasSecurity = $false
        Vpn = $null; Proxy = $null; Tor = $null; Relay = $null; Hosting = $null; Mobile = $null
        Type = $null; Operator = $null; Risk = $null; RiskLabel = $null
        City = $null; Region = $null; Country = $null; CountryCode = $null; Postal = $null; Lat = $null; Lon = $null
        Isp = $null; Org = $null; Asn = $null; Display = $null
    }

    try {
        switch ($Name) {
            'proxycheck.io' {
                $u = 'https://proxycheck.io/v2/' + $Ip + '?vpn=3&asn=1&risk=1'
                if ($Key) { $u += '&key=' + [Uri]::EscapeDataString($Key) }
                $j = Get-Json $u
                $st = [string]$j.status
                if ($st -eq 'denied' -or $st -eq 'error') { throw ([string]$j.message) }
                if ($st -eq 'warning') { $R.Note = [string]$j.message }
                $d = $null
                $p = $j.PSObject.Properties[$Ip]
                if ($null -ne $p) { $d = $p.Value }
                if ($null -eq $d) {
                    foreach ($p in $j.PSObject.Properties) {
                        if ($p.Value -is [System.Management.Automation.PSCustomObject]) { $d = $p.Value; break }
                    }
                }
                if ($null -eq $d) { throw 'No data returned' }
                $R.HasSecurity = $true
                $type = S $d.type
                $R.Type = $type
                $R.Proxy = YN $d.proxy
                $vpnField = YN $d.vpn
                if ($null -ne $vpnField) { $R.Vpn = $vpnField }
                else {
                    $R.Vpn = ($type -eq 'VPN')
                    if ($R.Vpn) { $R.Proxy = $false }
                }
                if ($type -eq 'VPN') { $R.Vpn = $true }
                $R.Tor = ($type -eq 'TOR')
                if ($R.Tor) { $R.Proxy = $true }
                $R.Hosting = ($type -eq 'Hosting')
                $R.Mobile = ($type -eq 'Wireless')
                if ($null -ne $d.operator) { $R.Operator = S $d.operator.name }
                $R.Risk = D $d.risk
                $R.City = S $d.city; $R.Region = S $d.region; $R.Country = S $d.country; $R.CountryCode = S $d.isocode
                $R.Postal = S $d.postcode; $R.Lat = D $d.latitude; $R.Lon = D $d.longitude
                $R.Isp = S $d.provider; $R.Org = S $d.organisation; $R.Asn = S $d.asn
            }
            'vpnapi.io' {
                if (-not $Key) { throw 'API key required' }
                $j = Get-Json ('https://vpnapi.io/api/' + $Ip + '?key=' + [Uri]::EscapeDataString($Key))
                if ($null -eq $j.security) {
                    if ($j.message) { throw ([string]$j.message) }
                    throw 'No data returned'
                }
                $R.HasSecurity = $true
                $R.Vpn = YN $j.security.vpn; $R.Proxy = YN $j.security.proxy; $R.Tor = YN $j.security.tor; $R.Relay = YN $j.security.relay
                $l = $j.location
                if ($null -ne $l) {
                    $R.City = S $l.city; $R.Region = S $l.region; $R.Country = S $l.country; $R.CountryCode = S $l.country_code
                    $R.Lat = D $l.latitude; $R.Lon = D $l.longitude
                }
                $n = $j.network
                if ($null -ne $n) {
                    $R.Isp = S $n.autonomous_system_organization; $R.Org = S $n.autonomous_system_organization
                    $R.Asn = S $n.autonomous_system_number
                }
            }
            'IPQualityScore' {
                if (-not $Key) { throw 'API key required' }
                $u = 'https://www.ipqualityscore.com/api/json/ip/' + [Uri]::EscapeDataString($Key) + '/' + $Ip + '?strictness=1&allow_public_access_points=true&lighter_penalties=true'
                $j = Get-Json $u
                if ($j.success -eq $false) { throw ([string]$j.message) }
                $R.HasSecurity = $true
                $R.Vpn = Any @((YN $j.vpn), (YN $j.active_vpn))
                $R.Tor = Any @((YN $j.tor), (YN $j.active_tor))
                $R.Proxy = YN $j.proxy
                if ($R.Vpn -eq $true -or $R.Tor -eq $true) { $R.Proxy = $false }   # IPQS sets proxy=true for VPN/Tor too
                $R.Mobile = YN $j.mobile
                $R.Type = S $j.connection_type
                $R.Hosting = ($R.Type -eq 'Data Center')
                $R.Risk = D $j.fraud_score; $R.RiskLabel = 'fraud score'
                $R.City = S $j.city; $R.Region = S $j.region; $R.CountryCode = S $j.country_code; $R.Country = $R.CountryCode
                $R.Postal = S $j.zip_code; $R.Lat = D $j.latitude; $R.Lon = D $j.longitude
                $R.Isp = S $j.ISP; $R.Org = S $j.organization
                if ($j.ASN) { $R.Asn = 'AS' + $j.ASN }
            }
            'ip-api.com' {
                $f = 'status,message,country,countryCode,regionName,city,zip,lat,lon,isp,org,as,mobile,proxy,hosting'
                if ($Key) { $u = 'https://pro.ip-api.com/json/' + $Ip + '?key=' + [Uri]::EscapeDataString($Key) + '&fields=' + $f }
                else      { $u = 'http://ip-api.com/json/' + $Ip + '?fields=' + $f }
                $j = Get-Json $u
                if ([string]$j.status -ne 'success') { throw ([string]$j.message) }
                $R.HasSecurity = $true
                $R.Proxy = YN $j.proxy            # ip-api's proxy flag covers proxies, VPNs and Tor exits
                $R.Hosting = YN $j.hosting
                $R.Mobile = YN $j.mobile
                $R.City = S $j.city; $R.Region = S $j.regionName; $R.Country = S $j.country; $R.CountryCode = S $j.countryCode
                $R.Postal = S $j.zip; $R.Lat = D $j.lat; $R.Lon = D $j.lon
                $R.Isp = S $j.isp; $R.Org = S $j.org
                if ($j.as) { $R.Asn = ([string]$j.as).Split(' ')[0] }
                if (-not $Key) { $R.Note = 'Free endpoint (non-commercial use only)' }
            }
            'ipwho.is' {
                $j = Get-Json ('https://ipwho.is/' + $Ip)
                if ($j.success -eq $false) { throw ([string]$j.message) }
                $R.City = S $j.city; $R.Region = S $j.region; $R.Country = S $j.country; $R.CountryCode = S $j.country_code
                $R.Postal = S $j.postal; $R.Lat = D $j.latitude; $R.Lon = D $j.longitude
                $c = $j.connection
                if ($null -ne $c) {
                    $R.Isp = S $c.isp; $R.Org = S $c.org
                    if ($c.asn) { $R.Asn = 'AS' + $c.asn }
                }
            }
            'geocode' {
                $q = $Query.Trim()
                if ($q -match '^\d{5}(-\d{4})?$') {
                    $u = 'https://nominatim.openstreetmap.org/search?format=jsonv2&limit=1&countrycodes=us&postalcode=' + $q.Substring(0, 5)
                } else {
                    $u = 'https://nominatim.openstreetmap.org/search?format=jsonv2&limit=1&q=' + [Uri]::EscapeDataString($q)
                }
                $j = Get-Json $u
                $first = @($j) | Select-Object -First 1
                if ($null -eq $first) { throw "Couldn't find that place" }
                $R.Lat = D $first.lat; $R.Lon = D $first.lon; $R.Display = S $first.display_name
                if ($null -eq $R.Lat) { throw "Couldn't find that place" }
            }
            default { throw "Unknown source $Name" }
        }
        $R.Ok = $true
    } catch {
        $R.Error = [string]$_.Exception.Message
        if (-not $R.Error) { $R.Error = [string]$_ }
    }
    return $R
}

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------
function Resolve-IpInput([string]$raw) {
    $s = $raw.Trim()
    if ($s -match '^\[([0-9a-fA-F:\.]+)\](:\d+)?$') { $s = $matches[1] }
    if ($s -match '^(\d{1,3}(\.\d{1,3}){3}):\d+$') { $s = $matches[1] }
    $addr = $null
    $looksLikeIp = ($s -match '^\d{1,3}(\.\d{1,3}){3}$') -or ($s.Contains(':') -and $s -match '^[0-9a-fA-F:\.%]+$')
    if (-not $looksLikeIp -or -not [System.Net.IPAddress]::TryParse($s, [ref]$addr)) {
        # Pull an IPv4 address out of pasted text such as "Client IP: 203.0.113.9 (Chrome)"
        $m = [regex]::Match($raw, '\b(\d{1,3}(?:\.\d{1,3}){3})\b')
        if ($m.Success -and [System.Net.IPAddress]::TryParse($m.Groups[1].Value, [ref]$addr)) { } else { return @{ Ok = $false; Reason = 'invalid' } }
    }
    if ($addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        $b = $addr.GetAddressBytes()
        $private = ($b[0] -eq 10) -or ($b[0] -eq 127) -or ($b[0] -eq 0) -or
                   ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
                   ($b[0] -eq 192 -and $b[1] -eq 168) -or
                   ($b[0] -eq 169 -and $b[1] -eq 254) -or
                   ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) -or
                   ($b[0] -ge 224)
        if ($private) { return @{ Ok = $false; Reason = 'private'; Ip = $addr.ToString() } }
    } else {
        $b = $addr.GetAddressBytes()
        if ($addr.IsIPv6LinkLocal -or $addr.IsIPv6SiteLocal -or $addr.IsIPv6Multicast -or
            $addr.Equals([System.Net.IPAddress]::IPv6Loopback) -or (($b[0] -band 0xFE) -eq 0xFC)) {
            return @{ Ok = $false; Reason = 'private'; Ip = $addr.ToString() }
        }
    }
    return @{ Ok = $true; Ip = $addr.ToString() }
}

function Get-Miles([double]$lat1, [double]$lon1, [double]$lat2, [double]$lon2) {
    $rad = [Math]::PI / 180
    $dLat = ($lat2 - $lat1) * $rad
    $dLon = ($lon2 - $lon1) * $rad
    $a = [Math]::Sin($dLat / 2) * [Math]::Sin($dLat / 2) +
         [Math]::Cos($lat1 * $rad) * [Math]::Cos($lat2 * $rad) * [Math]::Sin($dLon / 2) * [Math]::Sin($dLon / 2)
    return 2 * 3958.8 * [Math]::Atan2([Math]::Sqrt($a), [Math]::Sqrt(1 - $a))
}

function Format-Miles([double]$m) {
    if ($m -lt 10) { return ('{0:N1} mi' -f $m) }
    return ('{0:N0} mi' -f $m)
}

function Format-Coord($v) { return ([double]$v).ToString('0.####', $script:Inv) }

# Emoji are built from code points so this file stays plain ASCII (safe in Windows PowerShell 5.1).
function E([int[]]$cp) { return (($cp | ForEach-Object { [char]::ConvertFromUtf32($_) }) -join '') }
$script:Em = @{
    Green = E 0x1F7E2; Yellow = E 0x1F7E1; Red = E 0x1F534
    Ok = E 0x2705; No = E 0x274C; Warn = E 0x26A0, 0xFE0F; Pin = E 0x1F4CD
    Arrow = E 0x2192; Mid = E 0x00B7; Approx = E 0x2248
}

# Escape characters Discord would treat as formatting (names with _ or * etc.)
function Format-DiscordSafe([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }
    return [regex]::Replace($s, '([\\*_~`|\[\]])', '\$1')
}

function Get-DiscordFlag($c, [string]$yesKind) {
    # yesKind: 'bad' -> red X, 'warn' -> warning sign
    if ($c.True -gt 0) {
        $m = $script:Em.No; if ($yesKind -eq 'warn') { $m = $script:Em.Warn }
        return "$m Yes ($($c.True) of $($c.Total) sources)"
    }
    if ($c.False -gt 0) { return "$($script:Em.Ok) No" }
    return 'Unknown'
}

function Join-Place($city, $region, $country) {
    $parts = @()
    foreach ($p in @($city, $region, $country)) { if ($p -and ($parts -notcontains $p)) { $parts += $p } }
    return ($parts -join ', ')
}

function Get-FlagCount($list, [string]$prop) {
    $t = 0; $f = 0; $names = @()
    foreach ($r in $list) {
        if ($r[$prop] -eq $true) { $t++; $names += $r.Source }
        elseif ($r[$prop] -eq $false) { $f++ }
    }
    return [pscustomobject]@{ True = $t; False = $f; Total = $t + $f; Names = $names }
}

function Get-FlagDisplay($c, [string]$yesTone) {
    if (-not $yesTone) { $yesTone = 'bad' }
    if ($c.True -gt 0) { return @("Yes ($($c.True) of $($c.Total) sources)", $yesTone) }
    if ($c.False -gt 0) { return @('No', 'good') }
    return @('Unknown', 'muted')
}

# ---------------------------------------------------------------------------------------------
# UI builders
# ---------------------------------------------------------------------------------------------
function Add-KV($Panel, [string]$Label, [string]$Value, [string]$Tone) {
    $g = New-Object Windows.Controls.Grid
    $g.Margin = T 0 0 0 9
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = New-Object Windows.GridLength(108)
    $c2 = New-Object Windows.Controls.ColumnDefinition
    [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)

    $l = New-Object Windows.Controls.TextBlock
    $l.Text = $Label; $l.Foreground = $script:Br.MUTED; $l.FontSize = 13; $l.TextWrapping = 'Wrap'; $l.Margin = T 0 0 8 0

    $v = New-Object Windows.Controls.TextBlock
    $v.TextWrapping = 'Wrap'; $v.FontSize = 13.5
    if ([string]::IsNullOrWhiteSpace($Value)) { $Value = $script:Dash; $Tone = 'muted' }
    $toneKey = $null
    if ($Tone -eq 'good' -or $Tone -eq 'warn' -or $Tone -eq 'bad') { $toneKey = $Tone.ToUpperInvariant() }
    if ($toneKey) {
        $dot = New-Object Windows.Documents.Run(($script:Dot + ' '))
        $dot.Foreground = $script:Br[$toneKey]; $dot.FontSize = 10
        [void]$v.Inlines.Add($dot)
    }
    $run = New-Object Windows.Documents.Run($Value)
    if ($toneKey) { $run.Foreground = $script:Br[$toneKey]; $run.FontWeight = [Windows.FontWeights]::SemiBold }
    elseif ($Tone -eq 'muted') { $run.Foreground = $script:Br.MUTED }
    [void]$v.Inlines.Add($run)
    [Windows.Controls.Grid]::SetColumn($v, 1)

    [void]$g.Children.Add($l); [void]$g.Children.Add($v)
    [void]$Panel.Children.Add($g)
}

$script:SourceCols = @(1.15, 1.35, 2.0, 2.0, 1.6)

function Add-SourceRow($cells, $tones, [bool]$isHeader) {
    $border = New-Object Windows.Controls.Border
    $border.BorderBrush = $script:Br.DIVIDER
    $border.BorderThickness = T 0 0 0 1
    $border.Padding = T 0 8 0 8
    $g = New-Object Windows.Controls.Grid
    for ($i = 0; $i -lt $script:SourceCols.Count; $i++) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = New-Object Windows.GridLength($script:SourceCols[$i], [Windows.GridUnitType]::Star)
        [void]$g.ColumnDefinitions.Add($cd)
    }
    for ($i = 0; $i -lt $cells.Count; $i++) {
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Text = [string]$cells[$i]
        $tb.TextWrapping = 'Wrap'
        $tb.Margin = T 0 0 12 0
        $tb.VerticalAlignment = 'Top'
        if ($isHeader) {
            $tb.FontSize = 12; $tb.Foreground = $script:Br.MUTED; $tb.FontWeight = [Windows.FontWeights]::SemiBold
        } else {
            $tb.FontSize = 13
            $tone = $null
            if ($tones -and $i -lt $tones.Count) { $tone = $tones[$i] }
            if ($tone -eq 'good' -or $tone -eq 'warn' -or $tone -eq 'bad') {
                $tb.Foreground = $script:Br[$tone.ToUpperInvariant()]; $tb.FontWeight = [Windows.FontWeights]::SemiBold
            } elseif ($tone -eq 'muted') { $tb.Foreground = $script:Br.MUTED }
            if ($i -eq 0) { $tb.FontWeight = [Windows.FontWeights]::SemiBold }
        }
        [Windows.Controls.Grid]::SetColumn($tb, $i)
        [void]$g.Children.Add($tb)
    }
    $border.Child = $g
    [void]$script:UI.SourcesPanel.Children.Add($border)
}

function Set-Verdict([string]$Tone, [string]$Title, [string]$Detail) {
    $glyph = [char]0xE721; $fg = $script:Br.SUB; $bg = $script:Br.CARD; $bd = $script:Br.BORDER
    switch ($Tone) {
        'good' { $glyph = [char]0xE930; $fg = $script:Br.GOOD; $bg = $script:Br.GOODBG; $bd = $script:Br.GOODBORDER }
        'warn' { $glyph = [char]0xE7BA; $fg = $script:Br.WARN; $bg = $script:Br.WARNBG; $bd = $script:Br.WARNBORDER }
        'bad'  { $glyph = [char]0xEA39; $fg = $script:Br.BAD;  $bg = $script:Br.BADBG;  $bd = $script:Br.BADBORDER }
        'busy' { $glyph = [char]0xE895; $fg = $script:Br.ACCENT }
    }
    $script:UI.VerdictIcon.Text = [string]$glyph
    $script:UI.VerdictIcon.Foreground = $fg
    $script:UI.VerdictTitle.Foreground = $(if ($Tone -eq 'good' -or $Tone -eq 'warn' -or $Tone -eq 'bad') { $fg } else { $script:Br.TEXT })
    $script:UI.VerdictCard.Background = $bg
    $script:UI.VerdictCard.BorderBrush = $bd
    $script:UI.VerdictTitle.Text = $Title
    $script:UI.VerdictDetail.Text = $Detail
}

function Clear-Results {
    $script:UI.PanelConn.Children.Clear()
    $script:UI.PanelLoc.Children.Clear()
    $script:UI.PanelNet.Children.Clear()
    $script:UI.SourcesPanel.Children.Clear()
    $script:UI.BtnMap.Visibility = 'Collapsed'
    $script:UI.BtnCopy.IsEnabled = $false
    $script:UI.BtnDiscord.IsEnabled = $false
}

function Update-IdleStatus {
    $src = Get-EnabledSources
    $names = @($src | ForEach-Object { $_.Name }) -join ', '
    $txt = "Sources: $names."
    if ($script:Settings.UseProxycheck -and -not $script:Settings.ProxycheckKey) { $txt += ' proxycheck.io without a key allows 100 lookups/day.' }
    $detect = @($src | Where-Object { $_.Name -ne 'ipwho.is' }).Count
    if ($detect -lt 2) { $txt += ' Tip: add a free vpnapi.io key in Settings for a second VPN opinion.' }
    $script:UI.TxtStatus.Text = $txt
}

# ---------------------------------------------------------------------------------------------
# Lookup flow
# ---------------------------------------------------------------------------------------------
$script:Jobs = @()
$script:GeoCache = @{}
$script:Busy = $false

function Start-Lookup {
    if ($script:Busy) { return }
    $raw = $script:UI.TxtIp.Text
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Set-Verdict 'neutral' 'Enter an IP address' 'Type or paste the public IP address you want to check.'
        $script:UI.TxtIp.Focus() | Out-Null
        return
    }
    $parsed = Resolve-IpInput $raw
    if (-not $parsed.Ok) {
        Clear-Results
        if ($parsed.Reason -eq 'private') {
            Set-Verdict 'warn' 'Private or reserved address' "$($parsed.Ip) is an internal/LAN, loopback, CGNAT or reserved address, so it can't be located. Ask for the public IP instead (for example from whatismyip.com, or from your VPN gateway / sign-in logs)."
        } else {
            Set-Verdict 'warn' 'That does not look like an IP address' 'Enter an IPv4 address like 203.0.113.45 or an IPv6 address like 2001:db8::1.'
        }
        return
    }
    $ip = $parsed.Ip
    $script:UI.TxtIp.Text = $ip
    $sources = Get-EnabledSources
    if ($sources.Count -eq 0) {
        Set-Verdict 'warn' 'No data sources enabled' 'Open Settings and turn on at least one source.'
        return
    }

    $script:Busy = $true
    $script:Current = @{
        Ip = $ip
        Expected = $script:UI.TxtExpected.Text.Trim()
        Note = $script:UI.TxtNote.Text.Trim()
        Geo = $null
    }
    Clear-Results
    $script:UI.BtnCheck.IsEnabled = $false
    $script:UI.Busy.Visibility = 'Visible'
    Set-Verdict 'busy' "Checking $ip$([char]0x2026)" "Asking $($sources.Count) source(s) at once. This usually takes a couple of seconds."
    $script:UI.TxtStatus.Text = ''

    $script:Jobs = @()
    foreach ($s in $sources) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $script:Pool
        [void]$ps.AddScript($WorkerScript.ToString()).AddArgument($s.Name).AddArgument($ip).AddArgument([string]$s.Key).AddArgument('')
        $script:Jobs += [pscustomobject]@{ Name = $s.Name; PS = $ps; Handle = $ps.BeginInvoke() }
    }
    $exp = $script:Current.Expected
    if ($exp) {
        $ck = $exp.ToLowerInvariant()
        if ($script:GeoCache.ContainsKey($ck)) {
            $script:Current.Geo = $script:GeoCache[$ck]
        } else {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $script:Pool
            [void]$ps.AddScript($WorkerScript.ToString()).AddArgument('geocode').AddArgument('').AddArgument('').AddArgument($exp)
            $script:Jobs += [pscustomobject]@{ Name = 'geocode'; PS = $ps; Handle = $ps.BeginInvoke() }
        }
    }
    $script:StartedAt = Get-Date
    $script:Timer.Start()
}

function Complete-Lookup {
    $results = New-Object System.Collections.ArrayList
    foreach ($j in $script:Jobs) {
        $h = $null
        if (-not $j.Handle.IsCompleted) {
            try { [void]$j.PS.BeginStop($null, $null) } catch {}
            $h = @{ Source = $j.Name; Ok = $false; Error = 'Timed out' }
        } else {
            try {
                $out = $j.PS.EndInvoke($j.Handle)
                $h = $out | Select-Object -Last 1
                if ($h -is [System.Management.Automation.PSObject]) { $h = $h.PSObject.BaseObject }
                if ($h -isnot [hashtable]) { $h = @{ Source = $j.Name; Ok = $false; Error = 'No result' } }
            } catch {
                $h = @{ Source = $j.Name; Ok = $false; Error = $_.Exception.Message }
            } finally { $j.PS.Dispose() }
        }
        if ($j.Name -eq 'geocode') {
            $script:Current.Geo = $h
            if ($h.Ok -and $script:Current.Expected) { $script:GeoCache[$script:Current.Expected.ToLowerInvariant()] = $h }
        } else { [void]$results.Add($h) }
    }
    $script:Jobs = @()
    $elapsed = ((Get-Date) - $script:StartedAt).TotalSeconds
    try { Show-Results $results $elapsed }
    finally {
        $script:Busy = $false
        $script:UI.BtnCheck.IsEnabled = $true
        $script:UI.Busy.Visibility = 'Hidden'
    }
}

function Show-Results($results, [double]$elapsed) {
    $cur = $script:Current
    $ip = $cur.Ip
    $threshold = [int]$script:Settings.MilesThreshold
    if ($threshold -lt 1) { $threshold = 100 }

    $order = @('IPQualityScore', 'proxycheck.io', 'vpnapi.io', 'ipwho.is', 'ip-api.com')
    $all = @()
    foreach ($n in $order) { $all += @($results | Where-Object { $_.Source -eq $n }) }
    $ok  = @($all | Where-Object { $_.Ok })
    $sec = @($ok  | Where-Object { $_.HasSecurity })

    $anon     = @($sec | Where-Object { $_.Vpn -eq $true -or $_.Proxy -eq $true -or $_.Tor -eq $true })
    $relay    = @($sec | Where-Object { $_.Relay -eq $true })
    $hostHits = @($ok  | Where-Object { $_.Hosting -eq $true })
    $mobile   = @($ok  | Where-Object { $_.Mobile -eq $true })

    $vpnC   = Get-FlagCount $sec 'Vpn'
    $proxyC = Get-FlagCount $sec 'Proxy'
    $torC   = Get-FlagCount $sec 'Tor'
    $relayC = Get-FlagCount $sec 'Relay'
    $hostC  = Get-FlagCount $ok  'Hosting'
    $mobC   = Get-FlagCount $ok  'Mobile'

    function First-Value([string]$prop) {
        foreach ($r in $ok) { if ($r[$prop]) { return $r[$prop] } }
        return $null
    }

    # Location: take one source's whole answer so city/region/coords stay consistent
    $prim = $null
    foreach ($r in $ok) { if ($null -ne $r.Lat -and $null -ne $r.Lon -and $r.City) { $prim = $r; break } }
    if (-not $prim) { foreach ($r in $ok) { if ($null -ne $r.Lat -and $null -ne $r.Lon) { $prim = $r; break } } }

    $operator = First-Value 'Operator'
    $isp  = First-Value 'Isp'
    $org  = First-Value 'Org'
    $asn  = First-Value 'Asn'
    $ctype = $null
    foreach ($r in $ok) { if ($r.Source -eq 'proxycheck.io' -and $r.Type) { $ctype = $r.Type } }
    if (-not $ctype) { $ctype = First-Value 'Type' }

    # Spread between sources' coordinates
    $spread = $null
    if ($prim) {
        $spread = 0.0
        foreach ($r in $ok) {
            if ($null -ne $r.Lat -and $null -ne $r.Lon) {
                $d = Get-Miles $prim.Lat $prim.Lon $r.Lat $r.Lon
                if ($d -gt $spread) { $spread = $d }
            }
        }
    }

    # Distance to where they say they are
    $geo = $cur.Geo
    $distPrim = $null; $distMin = $null; $geoErr = $null
    if ($cur.Expected) {
        if ($geo -and $geo.Ok) {
            foreach ($r in $ok) {
                if ($null -ne $r.Lat -and $null -ne $r.Lon) {
                    $d = Get-Miles $geo.Lat $geo.Lon $r.Lat $r.Lon
                    if ($null -eq $distMin -or $d -lt $distMin) { $distMin = $d }
                }
            }
            if ($prim) { $distPrim = Get-Miles $geo.Lat $geo.Lon $prim.Lat $prim.Lon }
        } elseif ($geo) { $geoErr = $geo.Error } else { $geoErr = 'Location lookup did not run' }
    }

    # ---- Verdict ----
    $lines = New-Object System.Collections.ArrayList
    $tone = 'good'; $title = 'No VPN or proxy detected'
    if ($ok.Count -eq 0) {
        $tone = 'bad'; $title = 'Lookup failed'
        [void]$lines.Add('None of the sources answered. Check your internet connection or the errors under Results by source.')
    } elseif ($anon.Count -gt 0) {
        $tone = 'bad'; $title = 'VPN / proxy detected'
        $kinds = @()
        if ($vpnC.True -gt 0) { $kinds += 'VPN' }
        if ($proxyC.True -gt 0) { $kinds += 'proxy' }
        if ($torC.True -gt 0) { $kinds += 'Tor' }
        if ($kinds.Count -gt 0) {
            $k = $kinds -join ' / '
            $title = $k.Substring(0, 1).ToUpperInvariant() + $k.Substring(1) + ' detected'
        }
        [void]$lines.Add("Flagged by $($anon.Count) of $($sec.Count) detection source(s): $((@($anon | ForEach-Object { $_.Source })) -join ', ').")
        if ($operator) { [void]$lines.Add("Provider: $operator.") }
        [void]$lines.Add('The location shown is most likely the VPN server, not where the person actually is.')
    } elseif ($relay.Count -gt 0) {
        $tone = 'warn'; $title = 'Apple iCloud Private Relay'
        [void]$lines.Add('Traffic is going through Apple relay servers, which hide the real location. Ask the person to turn off Private Relay (or "Limit IP Address Tracking") and check again.')
    } elseif ($hostHits.Count -gt 0) {
        $tone = 'warn'; $title = 'Datacenter / hosting address'
        [void]$lines.Add('Not on a known VPN list, but the address belongs to a hosting or cloud provider. Home and office connections normally come from a consumer or business ISP, so this often means a VPN, proxy or remote desktop.')
    } elseif ($sec.Count -eq 0) {
        $tone = 'warn'; $title = 'VPN status unknown'
        [void]$lines.Add('No VPN-detection source returned a result, so only location and ISP are available. See Results by source below.')
    } else {
        $kind = 'ISP'
        if ($ctype) { $kind = $ctype.ToLowerInvariant() }
        [void]$lines.Add("Checked by $($sec.Count) detection source(s). This looks like an ordinary $kind connection$(if ($isp) { " from $isp" }).")
    }

    if ($cur.Expected -and $ok.Count -gt 0) {
        if ($null -ne $distMin) {
            $placeShort = (($geo.Display -split ',\s*') | Select-Object -First 3) -join ', '
            if (-not $placeShort) { $placeShort = $cur.Expected }
            if ($distMin -gt $threshold) {
                if ($tone -eq 'good') { $tone = 'warn'; $title = 'Location mismatch' }
                [void]$lines.Add("The IP maps about $(Format-Miles $distMin) from $placeShort, beyond your $threshold-mile limit.")
            } else {
                [void]$lines.Add("The IP maps within $(Format-Miles $distMin) of $placeShort.")
            }
        } elseif ($geoErr) {
            [void]$lines.Add("Couldn't place '$($cur.Expected)' on the map ($geoErr). Try 'City, State' or a 5-digit ZIP.")
        }
    }
    if ($mobile.Count -gt 0 -and $anon.Count -eq 0) {
        [void]$lines.Add('Mobile carrier addresses often map to a regional hub far from the user, so treat the location loosely.')
    }
    Set-Verdict $tone $title ($lines -join ' ')

    # ---- Connection card ----
    $p = $script:UI.PanelConn
    $x = Get-FlagDisplay $vpnC 'bad';  Add-KV $p 'VPN' $x[0] $x[1]
    $x = Get-FlagDisplay $proxyC 'bad'; Add-KV $p 'Proxy' $x[0] $x[1]
    $x = Get-FlagDisplay $torC 'bad';  Add-KV $p 'Tor' $x[0] $x[1]
    if ($relayC.Total -gt 0) { $x = Get-FlagDisplay $relayC 'warn'; Add-KV $p 'Private Relay' $x[0] $x[1] }
    $x = Get-FlagDisplay $hostC 'warn'; Add-KV $p 'Datacenter' $x[0] $x[1]
    if ($mobC.Total -gt 0) {
        if ($mobC.True -gt 0) { Add-KV $p 'Mobile carrier' 'Yes' '' } else { Add-KV $p 'Mobile carrier' 'No' '' }
    }
    if ($operator) { Add-KV $p 'VPN provider' $operator 'bad' }
    $riskSrc = $null
    foreach ($r in $ok) { if ($null -ne $r.Risk -and ($null -eq $riskSrc -or $r.Risk -gt $riskSrc.Risk)) { $riskSrc = $r } }
    if ($riskSrc) {
        $rt = 'good'; if ($riskSrc.Risk -ge 67) { $rt = 'bad' } elseif ($riskSrc.Risk -ge 34) { $rt = 'warn' }
        Add-KV $p 'Risk score' ("{0:N0}/100 ({1})" -f $riskSrc.Risk, $riskSrc.Source) $rt
    }

    # ---- Location card ----
    $p = $script:UI.PanelLoc
    if ($prim) {
        Add-KV $p 'City' $prim.City ''
        Add-KV $p 'Region' $prim.Region ''
        $country = $prim.Country
        if ($prim.CountryCode -and $prim.Country -and $prim.Country -ne $prim.CountryCode) { $country = "$($prim.Country) ($($prim.CountryCode))" }
        Add-KV $p 'Country' $country ''
        if ($prim.Postal) { Add-KV $p 'Postal code' $prim.Postal '' }
        Add-KV $p 'Coordinates' ("{0}, {1}" -f (Format-Coord $prim.Lat), (Format-Coord $prim.Lon)) ''
        Add-KV $p 'Precision' 'Approximate (city level), not a street address' 'muted'
        if ($null -ne $spread) {
            $locCount = @($ok | Where-Object { $null -ne $_.Lat }).Count
            if ($locCount -lt 2) { Add-KV $p 'Agreement' 'Only one source had a location' 'muted' }
            elseif ($spread -le 50) { Add-KV $p 'Agreement' "Sources agree (within $(Format-Miles $spread))" 'good' }
            else { Add-KV $p 'Agreement' "Sources differ by up to $(Format-Miles $spread)" 'warn' }
        }
        if ($cur.Expected) {
            if ($null -ne $distPrim) {
                $dt = 'good'; if ($distMin -gt $threshold) { $dt = 'warn' }
                $dtext = Format-Miles $distPrim
                if ($distMin -lt $distPrim - 1) { $dtext += " (closest source: $(Format-Miles $distMin))" }
                Add-KV $p 'Distance' "$dtext from $($cur.Expected)" $dt
            } else { Add-KV $p 'Distance' "Couldn't locate '$($cur.Expected)'" 'muted' }
        }
        $script:MapLat = $prim.Lat; $script:MapLon = $prim.Lon
        $script:UI.BtnMap.Visibility = 'Visible'
    } else {
        Add-KV $p 'Location' 'Not available' 'muted'
    }

    # ---- Network card ----
    $p = $script:UI.PanelNet
    Add-KV $p 'ISP' $isp ''
    if ($org -and $org -ne $isp) { Add-KV $p 'Organization' $org '' }
    Add-KV $p 'ASN' $asn ''
    if ($ctype) {
        $ct = ''
        if ($ctype -eq 'Hosting' -or $ctype -eq 'Data Center' -or $ctype -eq 'VPN') { $ct = 'warn' }
        Add-KV $p 'Connection type' $ctype $ct
    }
    Add-KV $p 'IP address' $ip ''

    # ---- Sources table ----
    Add-SourceRow @('Source', 'VPN / proxy', 'Location', 'ISP', 'Status') $null $true
    foreach ($r in $all) {
        if ($r.Ok) {
            if (-not $r.HasSecurity) { $det = 'Not checked'; $dt = 'muted' }
            else {
                $hits = @()
                if ($r.Vpn -eq $true) { $hits += 'VPN' }
                if ($r.Proxy -eq $true) { if ($r.Source -eq 'ip-api.com') { $hits += 'Proxy/VPN' } else { $hits += 'Proxy' } }
                if ($r.Tor -eq $true) { $hits += 'Tor' }
                if ($r.Relay -eq $true) { $hits += 'Private Relay' }
                if ($hits.Count -gt 0) { $det = $hits -join ', '; $dt = 'bad'; if ($hits.Count -eq 1 -and $hits[0] -eq 'Private Relay') { $dt = 'warn' } }
                elseif ($r.Hosting -eq $true) { $det = 'Datacenter'; $dt = 'warn' }
                else { $det = 'Clean'; $dt = 'good' }
            }
            $loc = Join-Place $r.City $r.Region $r.CountryCode
            if (-not $loc) { $loc = Join-Place $null $null $r.Country }
            $status = 'OK'; $st = 'muted'
            if ($r.Note) { $status = $r.Note; $st = 'warn' }
            Add-SourceRow @($r.Source, $det, $loc, $(if ($r.Isp) { $r.Isp } else { $script:Dash }), $status) @('', $dt, '', '', $st) $false
        } else {
            Add-SourceRow @($r.Source, $script:Dash, $script:Dash, $script:Dash, $r.Error) @('', 'muted', 'muted', 'muted', 'bad') $false
        }
    }

    # ---- Report + history ----
    $locText = ''
    if ($prim) { $locText = Join-Place $prim.City $prim.Region $prim.Country }
    $coordText = ''
    if ($prim) { $coordText = "{0}, {1}" -f (Format-Coord $prim.Lat), (Format-Coord $prim.Lon) }
    $vpnYes = 'Unknown'
    if ($sec.Count -gt 0) { if ($anon.Count -gt 0) { $vpnYes = "Yes ($($anon.Count) of $($sec.Count) sources)" } else { $vpnYes = "No ($($sec.Count) sources)" } }
    $srcSummary = @($all | ForEach-Object {
        if ($_.Ok) {
            $d = 'location only'
            if ($_.HasSecurity) {
                $d = 'clean'
                if ($_.Vpn -eq $true -or $_.Proxy -eq $true -or $_.Tor -eq $true) { $d = 'VPN/proxy' }
                elseif ($_.Relay -eq $true) { $d = 'Private Relay' }
                elseif ($_.Hosting -eq $true) { $d = 'datacenter' }
            }
            "$($_.Source): $d"
        } else { "$($_.Source): error - $($_.Error)" }
    }) -join '; '
    $distText = ''
    if ($null -ne $distPrim) { $distText = [Math]::Round($distPrim, 0) }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("IP Check report - $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    [void]$sb.AppendLine("IP address:   $ip")
    if ($cur.Note) { [void]$sb.AppendLine("Employee:     $($cur.Note)") }
    [void]$sb.AppendLine("Result:       $title")
    [void]$sb.AppendLine("VPN/proxy:    $vpnYes$(if ($operator) { " - provider: $operator" })")
    [void]$sb.AppendLine("Datacenter:   $((Get-FlagDisplay $hostC 'warn')[0])")
    [void]$sb.AppendLine("Location:     $(if ($locText) { "$locText ($coordText) - approximate, city level" } else { 'not available' })")
    if ($cur.Expected) {
        if ($null -ne $distPrim) { [void]$sb.AppendLine("Stated:       $($cur.Expected) - about $(Format-Miles $distPrim) away (limit $threshold mi)") }
        else { [void]$sb.AppendLine("Stated:       $($cur.Expected) - could not be located") }
    }
    [void]$sb.AppendLine("ISP:          $(if ($isp) { $isp } else { 'unknown' })$(if ($asn) { " ($asn)" })")
    if ($ctype) { [void]$sb.AppendLine("Type:         $ctype") }
    [void]$sb.AppendLine("Sources:      $srcSummary")
    $script:LastReport = $sb.ToString()
    $script:UI.BtnCopy.IsEnabled = $true

    # ---- Discord-formatted report ----
    $em = $script:Em
    $dot = $em.Green; if ($tone -eq 'warn') { $dot = $em.Yellow } elseif ($tone -eq 'bad') { $dot = $em.Red }
    $dc = New-Object System.Collections.ArrayList
    [void]$dc.Add("### $dot $title")
    [void]$dc.Add("**IP:** ``$ip``")
    if ($cur.Note) { [void]$dc.Add("**Employee:** $(Format-DiscordSafe $cur.Note)") }
    $vpnLine = 'Unknown'
    if ($sec.Count -gt 0) {
        if ($anon.Count -gt 0) { $vpnLine = "$($em.No) **Yes** ($($anon.Count) of $($sec.Count) sources)" }
        else { $vpnLine = "$($em.Ok) No ($($sec.Count) sources)" }
    }
    if ($operator) { $vpnLine += " $($em.Mid) provider: **$(Format-DiscordSafe $operator)**" }
    [void]$dc.Add("**VPN / proxy:** $vpnLine")
    [void]$dc.Add("**Datacenter:** $(Get-DiscordFlag $hostC 'warn')")
    if ($relayC.True -gt 0) { [void]$dc.Add("**Private Relay:** $(Get-DiscordFlag $relayC 'warn')") }
    if ($locText) {
        $mapUrl = "https://www.openstreetmap.org/?mlat={0}&mlon={1}#map=10/{0}/{1}" -f (Format-Coord $prim.Lat), (Format-Coord $prim.Lon)
        [void]$dc.Add("**Location:** $($em.Pin) [$(Format-DiscordSafe $locText)](<$mapUrl>)")
    } else {
        [void]$dc.Add('**Location:** not available')
    }
    if ($cur.Expected) {
        $stated = Format-DiscordSafe $cur.Expected
        if ($null -ne $distPrim) {
            $m = $em.Ok; if ($distMin -gt $threshold) { $m = $em.Warn }
            [void]$dc.Add("**Stated location:** $stated $($em.Arrow) $($em.Approx)$(Format-Miles $distPrim) away $m")
        } else {
            [void]$dc.Add("**Stated location:** $stated $($em.Arrow) couldn't be located")
        }
    }
    $ispLine = 'unknown'
    if ($isp) { $ispLine = Format-DiscordSafe $isp }
    if ($asn) { $ispLine += " ($asn)" }
    if ($ctype) { $ispLine += " $($em.Mid) $ctype" }
    [void]$dc.Add("**ISP:** $ispLine")
    $srcParts = @($all | ForEach-Object {
        if (-not $_.Ok) { "$($_.Source) $($em.Warn) error" }
        elseif (-not $_.HasSecurity) { "$($_.Source) (location only)" }
        elseif ($_.Vpn -eq $true -or $_.Proxy -eq $true -or $_.Tor -eq $true) { "$($_.Source) $($em.No)" }
        elseif ($_.Relay -eq $true -or $_.Hosting -eq $true) { "$($_.Source) $($em.Warn)" }
        else { "$($_.Source) $($em.Ok)" }
    })
    $sub = @()
    if ($coordText) { $sub += "$coordText $($em.Mid) approximate, city level" }
    if ($cur.Expected -and $null -ne $distPrim) { $sub += "limit $threshold mi" }
    $sub += "checked $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    [void]$dc.Add("-# Sources: $($srcParts -join " $($em.Mid) ")")
    [void]$dc.Add("-# $($sub -join " $($em.Mid) ")")
    $script:LastDiscord = ($dc -join "`n")
    $script:UI.BtnDiscord.IsEnabled = $true

    if ($script:Settings.SaveHistory -and $ok.Count -gt 0) {
        try {
            if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }
            [pscustomobject][ordered]@{
                Timestamp     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                IP            = $ip
                Employee      = $cur.Note
                Result        = $title
                VpnOrProxy    = $vpnYes
                VpnProvider   = $operator
                Datacenter    = (Get-FlagDisplay $hostC 'warn')[0]
                Location      = $locText
                Coordinates   = $coordText
                ISP           = $isp
                ASN           = $asn
                StatedLocation = $cur.Expected
                DistanceMiles = $distText
                Sources       = $srcSummary
            } | Export-Csv -Path $script:HistoryPath -Append -NoTypeInformation -Encoding UTF8
        } catch { Write-ErrorLog "History write failed: $($_.Exception.Message)" }
    }

    $failed = @($all | Where-Object { -not $_.Ok }).Count
    $status = "Done in {0:N1} s with {1} of {2} sources answering." -f $elapsed, $ok.Count, $all.Count
    if ($failed -gt 0) { $status += ' See Results by source for errors.' }
    $script:UI.TxtStatus.Text = $status
}

# ---------------------------------------------------------------------------------------------
# Settings dialog
# ---------------------------------------------------------------------------------------------
function Show-SettingsDialog {
    $w = New-XamlWindow $SettingsXaml
    Set-WindowChrome $w
    $w.Owner = $script:Win
    if ($script:Win.Icon) { $w.Icon = $script:Win.Icon }
    $script:SF = @{ Win = $w }
    foreach ($n in 'ChkPc', 'PwPc', 'ChkVa', 'PwVa', 'ChkIq', 'PwIq', 'ChkIa', 'PwIa', 'ChkIw', 'TxtMiles', 'ChkHist', 'BtnSave', 'BtnCancel', 'LnkPc', 'LnkVa', 'LnkIq', 'LnkIa') {
        $script:SF[$n] = $w.FindName($n)
    }
    $s = $script:Settings
    $script:SF.ChkPc.IsChecked = [bool]$s.UseProxycheck; $script:SF.PwPc.Password = [string]$s.ProxycheckKey
    $script:SF.ChkVa.IsChecked = [bool]$s.UseVpnapi;     $script:SF.PwVa.Password = [string]$s.VpnapiKey
    $script:SF.ChkIq.IsChecked = [bool]$s.UseIpqs;       $script:SF.PwIq.Password = [string]$s.IpqsKey
    $script:SF.ChkIa.IsChecked = [bool]$s.UseIpApi;      $script:SF.PwIa.Password = [string]$s.IpApiKey
    $script:SF.ChkIw.IsChecked = [bool]$s.UseIpwho
    $script:SF.TxtMiles.Text   = [string]$s.MilesThreshold
    $script:SF.ChkHist.IsChecked = [bool]$s.SaveHistory

    foreach ($ln in 'LnkPc', 'LnkVa', 'LnkIq', 'LnkIa') {
        $script:SF[$ln].Add_Click({ param($sender, $e) try { Start-Process $sender.NavigateUri.AbsoluteUri } catch {} })
    }
    # Typing a key turns its source on
    $script:SF.PwVa.Add_PasswordChanged({ if ($script:SF.PwVa.Password) { $script:SF.ChkVa.IsChecked = $true } })
    $script:SF.PwIq.Add_PasswordChanged({ if ($script:SF.PwIq.Password) { $script:SF.ChkIq.IsChecked = $true } })
    $script:SF.PwIa.Add_PasswordChanged({ if ($script:SF.PwIa.Password) { $script:SF.ChkIa.IsChecked = $true } })

    $script:SF.BtnCancel.Add_Click({ $script:SF.Win.Close() })
    $script:SF.BtnSave.Add_Click({
        try {
            $miles = 0
            if (-not [int]::TryParse($script:SF.TxtMiles.Text.Trim(), [ref]$miles) -or $miles -lt 1) { $miles = 100 }
            $script:Settings = @{
                UseProxycheck = [bool]$script:SF.ChkPc.IsChecked; ProxycheckKey = $script:SF.PwPc.Password.Trim()
                UseVpnapi     = [bool]$script:SF.ChkVa.IsChecked; VpnapiKey     = $script:SF.PwVa.Password.Trim()
                UseIpqs       = [bool]$script:SF.ChkIq.IsChecked; IpqsKey       = $script:SF.PwIq.Password.Trim()
                UseIpApi      = [bool]$script:SF.ChkIa.IsChecked; IpApiKey      = $script:SF.PwIa.Password.Trim()
                UseIpwho      = [bool]$script:SF.ChkIw.IsChecked
                MilesThreshold = $miles
                SaveHistory   = [bool]$script:SF.ChkHist.IsChecked
            }
            Save-Settings $script:Settings
            $script:SF.Win.Close()
            if (-not $script:Busy) { Update-IdleStatus }
        } catch { Show-Fatal $_ }
    })
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------------------------
try {
    $script:Settings = Read-Settings
    $script:Win = New-XamlWindow $MainXaml
    Set-WindowChrome $script:Win
    $icon = New-AppIcon
    if ($icon) { $script:Win.Icon = $icon }

    $script:UI = @{}
    foreach ($n in 'TxtIp', 'TxtExpected', 'TxtNote', 'BtnCheck', 'BtnSettings', 'BtnHistory', 'BtnCopy', 'BtnDiscord', 'BtnMap',
                   'VerdictCard', 'VerdictIcon', 'VerdictTitle', 'VerdictDetail', 'Busy',
                   'PanelConn', 'PanelLoc', 'PanelNet', 'SourcesPanel', 'TxtStatus') {
        $script:UI[$n] = $script:Win.FindName($n)
        if ($null -eq $script:UI[$n]) { throw "UI element '$n' was not found" }
    }

    $script:Pool = [runspacefactory]::CreateRunspacePool(1, 8)
    $script:Pool.Open()

    $script:Timer = New-Object Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $script:Timer.Add_Tick({
        try {
            $pending = @($script:Jobs | Where-Object { -not $_.Handle.IsCompleted }).Count
            $elapsed = ((Get-Date) - $script:StartedAt).TotalSeconds
            if ($pending -gt 0 -and $elapsed -lt 30) { return }
            $script:Timer.Stop()
            Complete-Lookup
        } catch {
            $script:Timer.Stop()
            $script:Busy = $false
            $script:UI.BtnCheck.IsEnabled = $true
            $script:UI.Busy.Visibility = 'Hidden'
            Show-Fatal $_
        }
    })

    $script:UI.BtnCheck.Add_Click({ try { Start-Lookup } catch { $script:Busy = $false; $script:UI.BtnCheck.IsEnabled = $true; Show-Fatal $_ } })
    $script:UI.BtnSettings.Add_Click({ try { Show-SettingsDialog } catch { Show-Fatal $_ } })
    $script:UI.BtnHistory.Add_Click({
        if (Test-Path $script:HistoryPath) { try { Invoke-Item $script:HistoryPath } catch { Start-Process notepad.exe $script:HistoryPath } }
        else { [void][System.Windows.MessageBox]::Show("No history yet. Lookups are saved to:`r`n$($script:HistoryPath)", 'IP Check', 'OK', 'Information') }
    })
    $script:UI.BtnCopy.Add_Click({
        if ($script:LastReport) {
            try {
                [System.Windows.Clipboard]::SetText($script:LastReport)
                $script:UI.TxtStatus.Text = 'Report copied to the clipboard.'
            } catch { $script:UI.TxtStatus.Text = "Couldn't access the clipboard - try again." }
        }
    })
    $script:UI.BtnDiscord.Add_Click({
        if ($script:LastDiscord) {
            try {
                [System.Windows.Clipboard]::SetText($script:LastDiscord)
                $script:UI.TxtStatus.Text = 'Copied for Discord - paste it into your message.'
            } catch { $script:UI.TxtStatus.Text = "Couldn't access the clipboard - try again." }
        }
    })
    $script:UI.BtnMap.Add_Click({
        if ($null -ne $script:MapLat) {
            $la = Format-Coord $script:MapLat; $lo = Format-Coord $script:MapLon
            Start-Process ("https://www.openstreetmap.org/?mlat={0}&mlon={1}#map=10/{0}/{1}" -f $la, $lo)
        }
    })
    $script:Win.Add_Closed({
        try { $script:Timer.Stop() } catch {}
        try { $script:Pool.Close(); $script:Pool.Dispose() } catch {}
    })
    $script:Win.Add_ContentRendered({ $script:UI.TxtIp.Focus() | Out-Null })

    Update-IdleStatus
    if ($script:FirstRun) {
        $script:UI.TxtStatus.Text = 'Works right away with proxycheck.io and ipwho.is. For better VPN detection, add free API keys in Settings.'
    }
    if ($Ip) { $script:UI.TxtIp.Text = $Ip }

    [void]$script:Win.ShowDialog()
} catch {
    Show-Fatal $_
}
