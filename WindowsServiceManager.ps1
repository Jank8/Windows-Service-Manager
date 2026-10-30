#Requires -Version 5.1

<#
.SYNOPSIS
    Windows Service Manager - a WPF GUI with a full dark theme and a custom title bar.

.DESCRIPTION
    - service list (Win32_Service) with sorting by clicking a column header
    - live search (name, display name, description, account, path, process; several words = AND,
      accents are ignored, so "usluga" also matches "Usluga")
    - state filter: All / Running / Stopped
    - Start / Stop / Restart; dependent services are stopped first and started again afterwards
    - startup type: Automatic / Automatic (delayed) / Manual / Disabled
    - operations run in the background, so the window never freezes
    - every wait has a timeout and can be cancelled with Esc
    - drivers are detected, and changes that can break booting need an extra confirmation
    - works on Windows PowerShell 5.1 (built into Windows 10/11) and on PowerShell 7+

    Shortcuts: F5 = refresh, Ctrl+F = search, Esc = cancel the running operation / clear the search.

.NOTES
    Version 1.0.0.
    Requires Windows PowerShell 5.1 (installed with Windows).
    Run: powershell.exe -File .\WindowsServiceManager.ps1  (or right-click > Run with PowerShell)
    The script restarts itself elevated (UAC) and in STA mode when needed.
    The console window stays open - useful for diagnostics.
#>

$script:AppVersion = '1.0.0'

# =====================================================================================
# 1. Administrator + STA (WPF requires STA, changing services requires elevation)
# =====================================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSta   = [Threading.Thread]::CurrentThread.GetApartmentState() -eq [Threading.ApartmentState]::STA
$relaunched = $env:SVC_MGR_RELAUNCHED -eq '1'

Write-Host ('=== Windows Service Manager {0} ===' -f $script:AppVersion) -ForegroundColor Cyan
Write-Host ("PowerShell {0}   Admin: {1}   STA: {2}   PID: {3}" -f $PSVersionTable.PSVersion, $isAdmin, $isSta, $PID) -ForegroundColor Cyan
Write-Host '-------------------------------------------' -ForegroundColor DarkGray

if ((-not $isAdmin -or -not $isSta) -and -not $relaunched) {
    if (-not $PSCommandPath) {
        Write-Warning 'Save the script to a .ps1 file and run it from there (administrator + STA required).'
        [void](Read-Host 'Press Enter to close')
        return
    }

    # Always relaunch into the PowerShell that ships with Windows; PowerShell 7 also runs this script,
    # so there is no reason to look for pwsh.exe first.
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $exe)) { $exe = (Get-Process -Id $PID).Path }

    $reasons = @()
    if (-not $isAdmin) { $reasons += 'UAC' }
    if (-not $isSta)   { $reasons += 'STA' }
    Write-Host ('Relaunch: {0}  [{1}]' -f $exe, ($reasons -join ', ')) -ForegroundColor Yellow

    $relaunch = @{
        FilePath     = $exe
        ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $PSCommandPath))
    }
    if (-not $isAdmin) { $relaunch.Verb = 'RunAs' }

    $env:SVC_MGR_RELAUNCHED = '1'
    try {
        Start-Process @relaunch
    }
    catch {
        Write-Warning ('Could not restart the script with the required privileges: ' + $_.Exception.Message)
        [void](Read-Host 'Press Enter to close')
    }
    finally {
        # The child process already inherited its own copy of the variable; keep this session clean.
        Remove-Item Env:\SVC_MGR_RELAUNCHED -ErrorAction SilentlyContinue
    }
    return
}

if (-not $isAdmin -or -not $isSta) {
    Write-Warning ('The window needs administrator rights and STA. Admin: {0}   STA: {1}' -f $isAdmin, $isSta)
    [void](Read-Host 'Press Enter to close')
    return
}

# =====================================================================================
# 2. Helper types (one row of the list + DPI calls) and WPF assemblies
# =====================================================================================
if (-not ('SvcMgr.SvcRow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace SvcMgr
{
    public class SvcRow
    {
        public string Name        { get; set; }
        public string DisplayName { get; set; }
        public string StateKey    { get; set; }
        public string State       { get; set; }
        public string StartupKey  { get; set; }
        public string StartupType { get; set; }
        public string Account     { get; set; }
        public string Path        { get; set; }
        public string Description { get; set; }
        public string Search      { get; set; }
        public string ProcessName { get; set; }
        public bool   IsDriver    { get; set; }
        public bool   AcceptStop  { get; set; }
        public uint   ProcessId   { get; set; }
    }

    public static class Native
    {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();
    }
}
'@
}

try {
    # -4 = DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (Windows 10 1703 and newer)
    if (-not [SvcMgr.Native]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
        [void][SvcMgr.Native]::SetProcessDPIAware()
    }
    Write-Host 'DPI awareness set. Loading WPF...' -ForegroundColor DarkGray
}
catch {
    # Older Windows: fall back to system DPI awareness.
    try { [void][SvcMgr.Native]::SetProcessDPIAware() } catch { }
    Write-Host 'DPI awareness set (fallback). Loading WPF...' -ForegroundColor DarkGray
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# =====================================================================================
# 3. XAML: resources (colors + styles), main window, dialog
# =====================================================================================
$script:XamlNs = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"'

$script:XamlRes = @'
<!-- Palette -->
<SolidColorBrush x:Key="BgBrush" Color="#18181B"/>
<SolidColorBrush x:Key="TitleBrush" Color="#121215"/>
<SolidColorBrush x:Key="SurfaceBrush" Color="#1E1E22"/>
<SolidColorBrush x:Key="Surface2Brush" Color="#27272D"/>
<SolidColorBrush x:Key="LineBrush" Color="#33333A"/>
<SolidColorBrush x:Key="TextBrush" Color="#E8E8EC"/>
<SolidColorBrush x:Key="DimBrush" Color="#9B9BA6"/>
<SolidColorBrush x:Key="FaintBrush" Color="#6C6C77"/>
<SolidColorBrush x:Key="AccentBrush" Color="#5B9CFF"/>
<SolidColorBrush x:Key="AccentStrongBrush" Color="#3B7BEA"/>
<SolidColorBrush x:Key="GreenBrush" Color="#4ADE80"/>
<SolidColorBrush x:Key="AmberBrush" Color="#F5B83D"/>
<SolidColorBrush x:Key="RedBrush" Color="#F2666B"/>
<SolidColorBrush x:Key="RowHoverBrush" Color="#25252B"/>
<SolidColorBrush x:Key="RowSelBrush" Color="#2A3B5E"/>

<!-- System color overrides (scrollbar corners, selections and so on).
     InactiveSelectionHighlightBrushKey is deliberately NOT overridden: on .NET Framework
     (Windows PowerShell 5.1) it resolves to the very same key as ControlBrushKey and the
     resource dictionary fails with a duplicate-key error. -->
<SolidColorBrush x:Key="{x:Static SystemColors.ControlBrushKey}" Color="#1E1E22"/>
<SolidColorBrush x:Key="{x:Static SystemColors.WindowBrushKey}" Color="#1E1E22"/>
<SolidColorBrush x:Key="{x:Static SystemColors.ControlTextBrushKey}" Color="#E8E8EC"/>
<SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#2A3B5E"/>
<SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#FFFFFF"/>

<!-- Caption buttons -->
<Style x:Key="CaptionBtn" TargetType="Button">
  <Setter Property="Width" Value="46"/>
  <Setter Property="Height" Value="40"/>
  <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
  <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
  <Setter Property="FontSize" Value="10"/>
  <Setter Property="Focusable" Value="False"/>
  <Setter Property="shell:WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="Transparent">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#2E2E35"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#3A3A43"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style x:Key="CloseBtn" TargetType="Button">
  <Setter Property="Width" Value="46"/>
  <Setter Property="Height" Value="40"/>
  <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
  <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
  <Setter Property="FontSize" Value="10"/>
  <Setter Property="Focusable" Value="False"/>
  <Setter Property="shell:WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="Transparent">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#E81123"/><Setter Property="Foreground" Value="White"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#B00E1B"/><Setter Property="Foreground" Value="White"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<!-- Generic buttons (hover = translucent overlay, works on any background color) -->
<Style x:Key="DarkBtn" TargetType="Button">
  <Setter Property="Background" Value="{StaticResource Surface2Brush}"/>
  <Setter Property="BorderBrush" Value="{StaticResource LineBrush}"/>
  <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
  <Setter Property="BorderThickness" Value="1"/>
  <Setter Property="Padding" Value="14,0"/>
  <Setter Property="Height" Value="34"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Grid x:Name="root" SnapsToDevicePixels="True">
          <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6"/>
          <Border x:Name="ov" Background="White" CornerRadius="6" Opacity="0" IsHitTestVisible="False"/>
          <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ov" Property="Opacity" Value="0.08"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="ov" Property="Opacity" Value="0.16"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="root" Property="Opacity" Value="0.38"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="AccentBtn" TargetType="Button" BasedOn="{StaticResource DarkBtn}">
  <Setter Property="Background" Value="#3B7BEA"/>
  <Setter Property="BorderBrush" Value="#5B9CFF"/>
  <Setter Property="Foreground" Value="White"/>
</Style>
<Style x:Key="GoodBtn" TargetType="Button" BasedOn="{StaticResource DarkBtn}">
  <Setter Property="Background" Value="#1F6B45"/>
  <Setter Property="BorderBrush" Value="#2A8A5A"/>
  <Setter Property="Foreground" Value="White"/>
</Style>
<Style x:Key="BadBtn" TargetType="Button" BasedOn="{StaticResource DarkBtn}">
  <Setter Property="Background" Value="#7A2B31"/>
  <Setter Property="BorderBrush" Value="#A33A41"/>
  <Setter Property="Foreground" Value="White"/>
</Style>

<Style x:Key="GhostBtn" TargetType="Button">
  <Setter Property="Foreground" Value="{StaticResource DimBrush}"/>
  <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
  <Setter Property="FontSize" Value="11"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Focusable" Value="False"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border Background="Transparent"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="{StaticResource TextBrush}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<!-- Segmented toggles (filters, startup type) -->
<Style x:Key="SegRadio" TargetType="RadioButton">
  <Setter Property="Foreground" Value="{StaticResource DimBrush}"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="RadioButton">
        <Border x:Name="bd" Background="Transparent" CornerRadius="6" Padding="14,6">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#33333B"/><Setter Property="Foreground" Value="{StaticResource TextBrush}"/></Trigger>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="bd" Property="Background" Value="{StaticResource AccentStrongBrush}"/><Setter Property="Foreground" Value="White"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.38"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<!-- Search box -->
<Style x:Key="SearchBorder" TargetType="Border">
  <Setter Property="Background" Value="{StaticResource Surface2Brush}"/>
  <Setter Property="BorderBrush" Value="{StaticResource LineBrush}"/>
  <Setter Property="BorderThickness" Value="1"/>
  <Setter Property="CornerRadius" Value="8"/>
  <Style.Triggers>
    <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter Property="BorderBrush" Value="{StaticResource AccentBrush}"/></Trigger>
  </Style.Triggers>
</Style>

<Style TargetType="TextBox">
  <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
  <Setter Property="CaretBrush" Value="{StaticResource TextBrush}"/>
  <Setter Property="SelectionBrush" Value="{StaticResource AccentStrongBrush}"/>
  <Setter Property="Background" Value="Transparent"/>
  <Setter Property="BorderThickness" Value="0"/>
  <Setter Property="Padding" Value="0"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="TextBox">
        <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
          <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center" Focusable="False" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
        </Border>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style TargetType="ToolTip">
  <Setter Property="Background" Value="{StaticResource Surface2Brush}"/>
  <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
  <Setter Property="BorderBrush" Value="{StaticResource LineBrush}"/>
  <Setter Property="Padding" Value="8,5"/>
</Style>

<!-- Scrollbars -->
<Style x:Key="ScrollThumb" TargetType="Thumb">
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Thumb">
        <Border x:Name="th" Background="#4A4A54" CornerRadius="4" Margin="2"/>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="th" Property="Background" Value="#6A6A76"/></Trigger>
          <Trigger Property="IsDragging" Value="True"><Setter TargetName="th" Property="Background" Value="#8A8A96"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="ScrollPage" TargetType="RepeatButton">
  <Setter Property="Focusable" Value="False"/>
  <Setter Property="IsTabStop" Value="False"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<ControlTemplate x:Key="VScrollTpl" TargetType="ScrollBar">
  <Grid Background="Transparent">
    <Track x:Name="PART_Track" IsDirectionReversed="True">
      <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
      <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}"/></Track.Thumb>
      <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
    </Track>
  </Grid>
</ControlTemplate>
<ControlTemplate x:Key="HScrollTpl" TargetType="ScrollBar">
  <Grid Background="Transparent">
    <Track x:Name="PART_Track" IsDirectionReversed="False">
      <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
      <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}"/></Track.Thumb>
      <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
    </Track>
  </Grid>
</ControlTemplate>
<Style TargetType="ScrollBar">
  <Setter Property="Background" Value="Transparent"/>
  <Setter Property="Width" Value="12"/>
  <Setter Property="Template" Value="{StaticResource VScrollTpl}"/>
  <Style.Triggers>
    <Trigger Property="Orientation" Value="Horizontal">
      <Setter Property="Width" Value="Auto"/>
      <Setter Property="Height" Value="12"/>
      <Setter Property="Template" Value="{StaticResource HScrollTpl}"/>
    </Trigger>
  </Style.Triggers>
</Style>

<!-- DataGrid -->
<Style x:Key="CellText" TargetType="TextBlock">
  <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
  <Setter Property="VerticalAlignment" Value="Center"/>
</Style>

<Style x:Key="GridHeader" TargetType="DataGridColumnHeader">
  <Setter Property="Foreground" Value="{StaticResource DimBrush}"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Padding" Value="12,0"/>
  <Setter Property="HorizontalContentAlignment" Value="Left"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="DataGridColumnHeader">
        <Grid>
          <Border x:Name="bd" Background="Transparent" BorderBrush="{StaticResource LineBrush}" BorderThickness="0,0,0,1">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <ContentPresenter Margin="{TemplateBinding Padding}" VerticalAlignment="Center" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
              <Path x:Name="arrow" Grid.Column="1" Visibility="Collapsed" Fill="{StaticResource AccentBrush}" Data="M0,4 L8,4 L4,0 Z" Margin="0,0,12,0" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5"/>
            </Grid>
          </Border>
          <Thumb x:Name="PART_RightHeaderGripper" HorizontalAlignment="Right" Width="6" Cursor="SizeWE">
            <Thumb.Template>
              <ControlTemplate TargetType="Thumb"><Border Background="Transparent"/></ControlTemplate>
            </Thumb.Template>
          </Thumb>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#25252B"/></Trigger>
          <Trigger Property="SortDirection" Value="Ascending"><Setter TargetName="arrow" Property="Visibility" Value="Visible"/></Trigger>
          <Trigger Property="SortDirection" Value="Descending">
            <Setter TargetName="arrow" Property="Visibility" Value="Visible"/>
            <Setter TargetName="arrow" Property="RenderTransform"><Setter.Value><RotateTransform Angle="180"/></Setter.Value></Setter>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style x:Key="GridRow" TargetType="DataGridRow">
  <Setter Property="Background" Value="Transparent"/>
  <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Style.Triggers>
    <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{StaticResource RowHoverBrush}"/></Trigger>
    <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{StaticResource RowSelBrush}"/></Trigger>
  </Style.Triggers>
</Style>

<Style x:Key="GridCell" TargetType="DataGridCell">
  <Setter Property="Background" Value="Transparent"/>
  <Setter Property="BorderThickness" Value="0"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="DataGridCell">
        <Border Background="Transparent" Padding="12,0" SnapsToDevicePixels="True">
          <ContentPresenter VerticalAlignment="Center"/>
        </Border>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
'@

$script:MainAttr = 'Title="Windows Service Manager" Width="1120" Height="740" MinWidth="940" MinHeight="600" WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResize" Background="#18181B" Foreground="#E8E8EC" FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display"'

$script:MainBody = @'
<shell:WindowChrome.WindowChrome>
  <shell:WindowChrome CaptionHeight="41" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
</shell:WindowChrome.WindowChrome>
<Border x:Name="RootBorder" Background="{StaticResource BgBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="40"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="28"/>
    </Grid.RowDefinitions>

    <!-- Title bar -->
    <Grid Grid.Row="0" Background="{StaticResource TitleBrush}">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="14,0,0,0">
        <TextBlock Text="&#xE713;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="{StaticResource AccentBrush}" VerticalAlignment="Center" Margin="0,0,10,0"/>
        <TextBlock Text="Service Manager" FontWeight="SemiBold" VerticalAlignment="Center"/>
        <TextBlock x:Name="TitleHost" Foreground="{StaticResource FaintBrush}" Margin="10,0,0,0" VerticalAlignment="Center"/>
      </StackPanel>
      <StackPanel Grid.Column="1" Orientation="Horizontal">
        <Button x:Name="BtnMin" Style="{StaticResource CaptionBtn}" Content="&#xE921;"/>
        <Button x:Name="BtnMax" Style="{StaticResource CaptionBtn}" Content="&#xE922;"/>
        <Button x:Name="BtnClose" Style="{StaticResource CloseBtn}" Content="&#xE8BB;"/>
      </StackPanel>
    </Grid>

    <!-- Toolbar: search, filters, refresh -->
    <Grid Grid.Row="1" Margin="16,14,16,12">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>

      <Border Style="{StaticResource SearchBorder}" Height="36">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="40"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="36"/>
          </Grid.ColumnDefinitions>
          <TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="{StaticResource DimBrush}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          <TextBlock x:Name="SearchHint" Grid.Column="1" Text="Search: name, display name, description, account...   (Ctrl+F)" Foreground="{StaticResource FaintBrush}" VerticalAlignment="Center" IsHitTestVisible="False"/>
          <TextBox x:Name="SearchBox" Grid.Column="1" VerticalAlignment="Center"/>
          <Button x:Name="BtnClear" Grid.Column="2" Style="{StaticResource GhostBtn}" Content="&#xE711;" Visibility="Collapsed" ToolTip="Clear (Esc)"/>
        </Grid>
      </Border>

      <Border Grid.Column="1" Margin="12,0,0,0" Height="36" Padding="3" Background="{StaticResource Surface2Brush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="8">
        <StackPanel Orientation="Horizontal">
          <RadioButton x:Name="FilterAll" Style="{StaticResource SegRadio}" GroupName="flt" IsChecked="True" Content="All" Padding="12,0"/>
          <RadioButton x:Name="FilterRunning" Style="{StaticResource SegRadio}" GroupName="flt" Content="Running"/>
          <RadioButton x:Name="FilterStopped" Style="{StaticResource SegRadio}" GroupName="flt" Content="Stopped"/>
        </StackPanel>
      </Border>

      <Button x:Name="BtnRefresh" Grid.Column="2" Style="{StaticResource DarkBtn}" Height="36" Margin="12,0,0,0" ToolTip="Refresh the list (F5)">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="&#xE895;" FontFamily="Segoe MDL2 Assets" FontSize="13" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <TextBlock Text="Refresh"/>
        </StackPanel>
      </Button>
    </Grid>

    <!-- Service list -->
    <Border Grid.Row="2" Margin="16,0" Background="{StaticResource SurfaceBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="8">
      <DataGrid x:Name="ServiceGrid"
                AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single" SelectionUnit="FullRow"
                HeadersVisibility="Column" GridLinesVisibility="None"
                CanUserAddRows="False" CanUserDeleteRows="False" CanUserResizeRows="False" CanUserReorderColumns="False"
                RowHeight="34" ColumnHeaderHeight="36" Background="Transparent" BorderThickness="0"
                HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto"
                Foreground="{StaticResource TextBrush}" FocusVisualStyle="{x:Null}"
                ColumnHeaderStyle="{StaticResource GridHeader}" RowStyle="{StaticResource GridRow}" CellStyle="{StaticResource GridCell}">
        <DataGrid.Columns>
          <DataGridTextColumn Header="Display name" Binding="{Binding DisplayName}" Width="2.2*" MinWidth="160" ElementStyle="{StaticResource CellText}"/>
          <DataGridTextColumn Header="Service name" Binding="{Binding Name}" Width="1.2*" MinWidth="110" ElementStyle="{StaticResource CellText}"/>
          <DataGridTextColumn Header="Process" Binding="{Binding ProcessName}" Width="0.9*" MinWidth="100" ElementStyle="{StaticResource CellText}"/>
          <DataGridTemplateColumn Header="State" Width="150" SortMemberPath="State">
            <DataGridTemplateColumn.CellTemplate>
              <DataTemplate>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                  <Ellipse Width="8" Height="8" Margin="0,0,9,0">
                    <Ellipse.Style>
                      <Style TargetType="Ellipse">
                        <Setter Property="Fill" Value="{StaticResource FaintBrush}"/>
                        <Style.Triggers>
                          <DataTrigger Binding="{Binding StateKey}" Value="Running"><Setter Property="Fill" Value="{StaticResource GreenBrush}"/></DataTrigger>
                          <DataTrigger Binding="{Binding StateKey}" Value="Paused"><Setter Property="Fill" Value="{StaticResource AmberBrush}"/></DataTrigger>
                          <DataTrigger Binding="{Binding StateKey}" Value="Pending"><Setter Property="Fill" Value="{StaticResource AmberBrush}"/></DataTrigger>
                        </Style.Triggers>
                      </Style>
                    </Ellipse.Style>
                  </Ellipse>
                  <TextBlock Text="{Binding State}"/>
                </StackPanel>
              </DataTemplate>
            </DataGridTemplateColumn.CellTemplate>
          </DataGridTemplateColumn>
          <DataGridTemplateColumn Header="Startup type" Width="210" SortMemberPath="StartupType">
            <DataGridTemplateColumn.CellTemplate>
              <DataTemplate>
                <TextBlock Text="{Binding StartupType}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis">
                  <TextBlock.Style>
                    <Style TargetType="TextBlock">
                      <Style.Triggers>
                        <DataTrigger Binding="{Binding StartupKey}" Value="Disabled"><Setter Property="Foreground" Value="{StaticResource RedBrush}"/></DataTrigger>
                      </Style.Triggers>
                    </Style>
                  </TextBlock.Style>
                </TextBlock>
              </DataTemplate>
            </DataGridTemplateColumn.CellTemplate>
          </DataGridTemplateColumn>
          <DataGridTextColumn Header="Account" Binding="{Binding Account}" Width="1.2*" MinWidth="110" ElementStyle="{StaticResource CellText}"/>
        </DataGrid.Columns>
      </DataGrid>
    </Border>

    <!-- Details and actions -->
    <Border Grid.Row="3" Margin="16,12,16,12" Padding="18,14" Background="{StaticResource SurfaceBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="8">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel Margin="0,0,24,0" VerticalAlignment="Center">
          <TextBlock x:Name="DetName" Text="Select a service from the list" FontSize="16" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
          <TextBlock x:Name="DetDesc" Foreground="{StaticResource DimBrush}" TextWrapping="Wrap" TextTrimming="CharacterEllipsis" MaxHeight="36" Margin="0,4,0,0"/>
          <TextBlock x:Name="DetMeta" FontSize="12" Foreground="{StaticResource DimBrush}" TextTrimming="CharacterEllipsis" Margin="0,8,0,0"/>
          <TextBlock x:Name="DetPath" FontFamily="Consolas" FontSize="11.5" Foreground="{StaticResource FaintBrush}" TextTrimming="CharacterEllipsis" Margin="0,4,0,0"/>
        </StackPanel>

        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnStart" Style="{StaticResource GoodBtn}" MinWidth="116" Margin="0,0,8,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE768;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <TextBlock Text="Start"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnStop" Style="{StaticResource BadBtn}" MinWidth="116" Margin="0,0,8,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE71A;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <TextBlock Text="Stop"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnRestart" Style="{StaticResource DarkBtn}" MinWidth="150">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <TextBlock Text="Restart"/>
              </StackPanel>
            </Button>
          </StackPanel>

          <TextBlock Text="Startup type" FontSize="12" Foreground="{StaticResource DimBrush}" HorizontalAlignment="Right" Margin="0,14,0,6"/>
          <Border HorizontalAlignment="Right" Padding="3" Background="{StaticResource Surface2Brush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="8">
            <StackPanel Orientation="Horizontal">
              <RadioButton x:Name="RbAuto" Style="{StaticResource SegRadio}" GroupName="start" Tag="Auto" Content="Automatic"/>
              <RadioButton x:Name="RbDelayed" Style="{StaticResource SegRadio}" GroupName="start" Tag="AutoDelayed" Content="Automatic (delayed)"/>
              <RadioButton x:Name="RbManual" Style="{StaticResource SegRadio}" GroupName="start" Tag="Manual" Content="Manual"/>
              <RadioButton x:Name="RbDisabled" Style="{StaticResource SegRadio}" GroupName="start" Tag="Disabled" Content="Disabled"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Status bar -->
    <Grid Grid.Row="4" Background="{StaticResource TitleBrush}">
      <ProgressBar x:Name="Progress" IsIndeterminate="True" Height="2" VerticalAlignment="Top" Visibility="Collapsed" Background="Transparent" Foreground="{StaticResource AccentBrush}" BorderThickness="0"/>
      <Grid Margin="16,0">
        <TextBlock x:Name="StatusLeft" FontSize="12" Foreground="{StaticResource DimBrush}" VerticalAlignment="Center"/>
        <TextBlock x:Name="StatusMsg" FontSize="12" Foreground="{StaticResource DimBrush}" VerticalAlignment="Center" HorizontalAlignment="Right"/>
      </Grid>
    </Grid>
  </Grid>
</Border>
'@

$script:DlgAttr = 'Width="480" SizeToContent="Height" ResizeMode="NoResize" WindowStyle="None" ShowInTaskbar="False" WindowStartupLocation="CenterOwner" Background="#18181B" BorderBrush="#33333A" BorderThickness="1" Foreground="#E8E8EC" FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display"'

$script:DlgBody = @'
<Grid>
  <Grid.RowDefinitions>
    <RowDefinition Height="40"/>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="Auto"/>
  </Grid.RowDefinitions>
  <Grid x:Name="DlgTitleBar" Background="{StaticResource TitleBrush}">
    <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0">
      <TextBlock x:Name="DlgIcon" FontFamily="Segoe MDL2 Assets" FontSize="16" VerticalAlignment="Center" Margin="0,0,10,0"/>
      <TextBlock x:Name="DlgTitle" FontWeight="SemiBold" VerticalAlignment="Center"/>
    </StackPanel>
  </Grid>
  <TextBlock x:Name="DlgMsg" Grid.Row="1" Margin="20,18,20,20" TextWrapping="Wrap" LineHeight="20"/>
  <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="16,0,16,16">
    <Button x:Name="DlgNo" Style="{StaticResource DarkBtn}" MinWidth="96" Margin="0,0,8,0" Content="Cancel"/>
    <Button x:Name="DlgYes" Style="{StaticResource AccentBtn}" MinWidth="96" Content="Yes"/>
  </StackPanel>
</Grid>
'@

function New-WpfWindow {
    param([string]$Attributes, [string]$Body)
    $xaml = '<Window {0} {1}><Window.Resources>{2}</Window.Resources>{3}</Window>' -f $script:XamlNs, $Attributes, $script:XamlRes, $Body
    [System.Windows.Markup.XamlReader]::Parse($xaml)
}

# =====================================================================================
# 4. Application state, labels, background work
# =====================================================================================
$script:Busy                = $false
$script:Job                 = $null
$script:Pool                = $null
$script:Ctx                 = $null
$script:PendingSelect       = $null
$script:PendingStatus       = $null
$script:CancelRequested     = $false
$script:StateFilter         = 'All'
$script:Terms               = @()
$script:OperationTimeoutSec = 60

$script:StateText = @{
    'Running'          = 'Running'
    'Stopped'          = 'Stopped'
    'Paused'           = 'Paused'
    'Start Pending'    = 'Starting...'
    'Stop Pending'     = 'Stopping...'
    'Continue Pending' = 'Resuming...'
    'Pause Pending'    = 'Pausing...'
}
$script:StartupText = @{
    'Auto'        = 'Automatic'
    'AutoDelayed' = 'Automatic (delayed)'
    'Manual'      = 'Manual'
    'Disabled'    = 'Disabled'
    'Boot'        = 'Boot'
    'System'      = 'System'
}
$script:ScMode = @{ 'Auto' = 'auto'; 'AutoDelayed' = 'delayed-auto'; 'Manual' = 'demand'; 'Disabled' = 'disabled' }

# Work done in a separate runspace (never blocks the UI).
# Only the body of the script block is transferred, so every helper it needs lives inside it.
$script:Work = @{
    List = {
        $allServices = Get-CimInstance -ClassName Win32_Service -Property `
            Name, DisplayName, State, StartMode, DelayedAutoStart,
            StartName, PathName, Description, AcceptStop, ProcessId, ServiceType

        # PID -> process name (one call instead of one per service)
        $processMap = @{}
        foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
            $processMap[[int]$process.Id] = $process.ProcessName + '.exe'
        }

        foreach ($service in $allServices) {
            [pscustomobject]@{
                Name        = $service.Name
                DisplayName = $service.DisplayName
                State       = $service.State
                StartMode   = $service.StartMode
                Delayed     = [bool]$service.DelayedAutoStart
                LogOn       = $service.StartName
                Path        = $service.PathName
                Description = $service.Description
                AcceptStop  = [bool]$service.AcceptStop
                ProcessId   = [uint32]$service.ProcessId
                ServiceType = $service.ServiceType
                ProcessName = if ($service.ProcessId -gt 0) { $processMap[[int]$service.ProcessId] } else { '' }
            }
        }
    }

    Action = {
        param($Operation, $Name, $TimeoutSec, $Cancellation)

        $ErrorActionPreference = 'Stop'

        function Wait-SvcStatus {
            param($Service, $Status, $TimeoutSec, $Cancellation)
            $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
            while ($true) {
                $Service.Refresh()
                if ($Service.Status -eq $Status) { return }
                if ($Cancellation -and $Cancellation.IsCancellationRequested) {
                    throw (New-Object System.OperationCanceledException('The operation was cancelled.'))
                }
                if ([DateTime]::UtcNow -gt $deadline) {
                    throw (New-Object System.TimeoutException((
                        "Timed out after {0} s while waiting for service '{1}' to reach the state '{2}'." -f $TimeoutSec, $Service.ServiceName, $Status)))
                }
                Start-Sleep -Milliseconds 300
            }
        }

        function Stop-OneService {
            param($Service, $TimeoutSec, $Cancellation)
            $Service.Refresh()
            if ($Service.Status -eq 'Stopped') { return }
            if (-not $Service.CanStop) {
                throw ("Service '{0}' does not accept stop requests." -f $Service.ServiceName)
            }
            $Service.Stop()
            Wait-SvcStatus -Service $Service -Status 'Stopped' -TimeoutSec $TimeoutSec -Cancellation $Cancellation
        }

        function Start-OneService {
            param($Service, $TimeoutSec, $Cancellation)
            $Service.Refresh()
            if ($Service.Status -eq 'Running') { return }
            if ($Service.Status -eq 'Paused') { $Service.Continue() }
            else { $Service.Start() }
            Wait-SvcStatus -Service $Service -Status 'Running' -TimeoutSec $TimeoutSec -Cancellation $Cancellation
        }

        # Transitive dependents, deepest first (that is the order they have to be stopped in).
        function Get-DependentTree {
            param($Service, $List, $Seen)
            foreach ($dependent in @($Service.DependentServices)) {
                if ($dependent.Status -eq 'Stopped') { continue }
                if ($Seen.ContainsKey($dependent.ServiceName)) { continue }
                $Seen[$dependent.ServiceName] = $true
                Get-DependentTree -Service $dependent -List $List -Seen $Seen
                [void]$List.Add($dependent)
            }
        }

        $service    = Get-Service -Name $Name -ErrorAction Stop
        $dependents = New-Object System.Collections.ArrayList
        $seen       = @{}

        if ($Operation -ne 'Start') {
            Get-DependentTree -Service $service -List $dependents -Seen $seen
        }

        switch ($Operation) {
            'Start' {
                Start-OneService -Service $service -TimeoutSec $TimeoutSec -Cancellation $Cancellation
            }
            'Stop' {
                foreach ($dependent in $dependents) {
                    Stop-OneService -Service $dependent -TimeoutSec $TimeoutSec -Cancellation $Cancellation
                }
                Stop-OneService -Service $service -TimeoutSec $TimeoutSec -Cancellation $Cancellation
            }
            'Restart' {
                foreach ($dependent in $dependents) {
                    Stop-OneService -Service $dependent -TimeoutSec $TimeoutSec -Cancellation $Cancellation
                }
                Stop-OneService -Service $service -TimeoutSec $TimeoutSec -Cancellation $Cancellation
                Start-OneService -Service $service -TimeoutSec $TimeoutSec -Cancellation $Cancellation
                for ($index = $dependents.Count - 1; $index -ge 0; $index--) {
                    Start-OneService -Service $dependents[$index] -TimeoutSec $TimeoutSec -Cancellation $Cancellation
                }
            }
            default { throw ("Unknown operation: {0}" -f $Operation) }
        }

        [pscustomobject]@{
            Operation  = $Operation
            Name       = $service.ServiceName
            Dependents = $dependents.Count
        }
    }

    Startup = {
        param($Name, $Mode)
        $ErrorActionPreference = 'Stop'

        # The built-in Set-Service cannot set a delayed automatic start, so sc.exe is used.
        # sc.exe prints in the OEM code page, so make sure its message is decoded correctly.
        try {
            [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(
                [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
        }
        catch { }

        $sc = Join-Path $env:SystemRoot 'System32\sc.exe'
        $output = & $sc config $Name 'start=' $Mode 2>&1
        if ($LASTEXITCODE -ne 0) {
            # The native message is localized, so put a readable cause in front of it.
            $hint = switch ($LASTEXITCODE) {
                5    { 'Access is denied. Run the tool as administrator.' }
                87   { 'sc.exe rejected the parameter (invalid startup type).' }
                1060 { 'The service does not exist (it may have just been removed).' }
                1072 { 'The service is marked for deletion.' }
                default { 'sc.exe exited with code {0}.' -f $LASTEXITCODE }
            }
            $text = (($output | ForEach-Object { $_.ToString() }) -join ' ').Trim()
            if ($text) { throw ($hint + "`n" + $text) }
            throw $hint
        }
    }
}

function Get-ErrorText {
    param([Exception]$Ex)
    if ($Ex -is [System.Management.Automation.MethodInvocationException] -and $Ex.InnerException) { $Ex = $Ex.InnerException }
    $messages = New-Object 'System.Collections.Generic.List[string]'
    while ($Ex) {
        if ($Ex.Message -and -not $messages.Contains($Ex.Message)) { $messages.Add($Ex.Message) }
        $Ex = $Ex.InnerException
    }
    ($messages -join "`n").Trim()
}

function Get-RunspacePool {
    if (-not $script:Pool) {
        $script:Pool = [runspacefactory]::CreateRunspacePool(1, 1)
        $script:Pool.Open()
    }
    $script:Pool
}

function Start-Background {
    param(
        [scriptblock]$Work,
        [object[]]$Arguments = @(),
        [scriptblock]$OnDone,
        [switch]$Cancellable
    )

    if ($script:Job) {
        Set-Status 'Another operation is still running.' 'Error'
        return $false
    }

    $powerShell = [powershell]::Create()
    $powerShell.RunspacePool = Get-RunspacePool
    [void]$powerShell.AddScript($Work.ToString())
    foreach ($argument in $Arguments) { [void]$powerShell.AddArgument($argument) }

    $cancellation = $null
    if ($Cancellable) {
        $cancellation = New-Object System.Threading.CancellationTokenSource
        [void]$powerShell.AddArgument($cancellation)
    }

    try {
        $script:Job = @{
            PS          = $powerShell
            Handle      = $powerShell.BeginInvoke()
            OnDone      = $OnDone
            Cts         = $cancellation
            Cancellable = $Cancellable.IsPresent
        }
        $script:CancelRequested = $false
        $script:Timer.Start()
        Write-Host '[BG] Operation started.' -ForegroundColor DarkGray
        return $true
    }
    catch {
        if ($cancellation) { try { $cancellation.Dispose() } catch { } }
        try { $powerShell.Dispose() } catch { }
        $script:Job = $null
        Set-Busy $false
        Set-Status ('Could not start the background operation: ' + $_.Exception.Message) 'Error'
        return $false
    }
}

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(100)
$script:Timer.Add_Tick({
    $job = $script:Job
    if (-not $job -or -not $job.Handle.IsCompleted) { return }

    $script:Timer.Stop()
    $script:Job = $null

    $result    = $null
    $errorText = $null
    $cancelled = $script:CancelRequested
    $script:CancelRequested = $false

    try { $result = $job.PS.EndInvoke($job.Handle) }
    catch {
        if (-not $cancelled) { $errorText = Get-ErrorText $_.Exception }
    }

    if (-not $cancelled -and $job.PS.Streams.Error.Count -gt 0) {
        $streamError = ($job.PS.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
        if (-not $errorText) { $errorText = $streamError }
        else { Write-Host ('[BG] Error stream: ' + $streamError) -ForegroundColor Yellow }
    }

    try { $job.PS.Dispose() } catch { }
    if ($job.Cts) { try { $job.Cts.Dispose() } catch { } }

    if ($errorText) { Write-Host ('[BG] Failed: ' + $errorText) -ForegroundColor Red }
    else { Write-Host '[BG] Finished.' -ForegroundColor DarkGray }

    try { & $job.OnDone $result $errorText $cancelled }
    catch {
        Set-Busy $false
        Set-Status ('Unexpected error: ' + $_.Exception.Message) 'Error'
    }
})

function Request-Cancel {
    $job = $script:Job
    if (-not $job -or -not $job.Cancellable -or $script:CancelRequested) { return }
    $script:CancelRequested = $true
    Set-Status 'Cancelling...' 'Busy'
    try { if ($job.Cts) { $job.Cts.Cancel() } } catch { }
    try { $job.PS.Stop() } catch { }
}

# =====================================================================================
# 5. Main window and dialogs
# =====================================================================================
$script:Win = New-WpfWindow $script:MainAttr $script:MainBody

$script:UI = @{}
foreach ($name in 'RootBorder', 'TitleHost', 'BtnMin', 'BtnMax', 'BtnClose',
                   'SearchBox', 'SearchHint', 'BtnClear', 'FilterAll', 'FilterRunning', 'FilterStopped', 'BtnRefresh',
                   'ServiceGrid', 'DetName', 'DetDesc', 'DetMeta', 'DetPath',
                   'BtnStart', 'BtnStop', 'BtnRestart', 'RbAuto', 'RbDelayed', 'RbManual', 'RbDisabled',
                   'StatusLeft', 'StatusMsg', 'Progress') {
    $script:UI[$name] = $script:Win.FindName($name)
}
$script:UI.StartupRadios = @($script:UI.RbAuto, $script:UI.RbDelayed, $script:UI.RbManual, $script:UI.RbDisabled)
$script:UI.TitleHost.Text = '-  {0}   |   v{1}' -f $env:COMPUTERNAME, $script:AppVersion

$script:Rows = New-Object 'System.Collections.ObjectModel.ObservableCollection[SvcMgr.SvcRow]'
$script:UI.ServiceGrid.ItemsSource = $script:Rows
$script:View = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:Rows)
$script:View.Filter = [System.Predicate[object]]{
    param($row)
    if ($script:StateFilter -ne 'All' -and $row.StateKey -ne $script:StateFilter) { return $false }
    $search = [string]$row.Search
    foreach ($term in $script:Terms) {
        if (-not $search -or -not $search.Contains($term)) { return $false }
    }
    return $true
}

function Show-Dialog {
    param(
        [string]$Title,
        [string]$Message,
        [ValidateSet('Info', 'Error', 'Confirm')][string]$Kind = 'Info',
        [string]$YesText
    )
    $dlg = New-WpfWindow $script:DlgAttr $script:DlgBody
    $elements = @{}
    foreach ($name in 'DlgTitleBar', 'DlgIcon', 'DlgTitle', 'DlgMsg', 'DlgNo', 'DlgYes') {
        $elements[$name] = $dlg.FindName($name)
    }

    $elements.DlgTitle.Text = $Title
    $elements.DlgMsg.Text   = $Message
    switch ($Kind) {
        'Error'   { $elements.DlgIcon.Text = [string][char]0xE783; $elements.DlgIcon.Foreground = $dlg.FindResource('RedBrush') }
        'Confirm' { $elements.DlgIcon.Text = [string][char]0xE7BA; $elements.DlgIcon.Foreground = $dlg.FindResource('AmberBrush') }
        default   { $elements.DlgIcon.Text = [string][char]0xE946; $elements.DlgIcon.Foreground = $dlg.FindResource('AccentBrush') }
    }
    if ($Kind -eq 'Confirm') {
        $elements.DlgYes.Content = if ($YesText) { $YesText } else { 'Yes' }
    }
    else {
        $elements.DlgNo.Visibility = 'Collapsed'
        $elements.DlgYes.Content   = 'OK'
    }
    $elements.DlgYes.IsDefault = $true

    $elements.DlgYes.Add_Click({ param($sender) [System.Windows.Window]::GetWindow($sender).DialogResult = $true })
    $elements.DlgNo.Add_Click({ param($sender) [System.Windows.Window]::GetWindow($sender).DialogResult = $false })
    $elements.DlgTitleBar.Add_MouseLeftButtonDown({
        param($sender)
        try { [System.Windows.Window]::GetWindow($sender).DragMove() } catch { }
    })
    $dlg.Add_PreviewKeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) { $sender.DialogResult = $false }
    })

    if ($script:Win -and $script:Win.IsVisible) { $dlg.Owner = $script:Win }
    else { $dlg.WindowStartupLocation = 'CenterScreen' }

    return [bool]$dlg.ShowDialog()
}

function Set-Status {
    param([string]$Text, [string]$Kind = 'Info')
    $key = switch ($Kind) {
        'Ok'    { 'GreenBrush' }
        'Error' { 'RedBrush' }
        'Busy'  { 'AccentBrush' }
        default { 'DimBrush' }
    }
    $script:UI.StatusMsg.Text       = ($Text -replace '\s+', ' ').Trim()
    $script:UI.StatusMsg.Foreground = $script:Win.FindResource($key)
}

# Accents are stripped so that "usluga" also matches "Usluga".
function ConvertTo-FoldedText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $decomposed = $Text.Normalize([System.Text.NormalizationForm]::FormD)
    # \p{Mn} are the non-spacing marks that NFD just separated from the base letters.
    $folded = [regex]::Replace($decomposed, '\p{Mn}', '')
    # "l with stroke" has no canonical decomposition, so it needs manual mapping.
    $folded.Replace([char]0x0142, [char]0x006C).Replace([char]0x0141, [char]0x004C)
}

function ConvertTo-SvcRow {
    param($Service)

    $startupKey = [string]$Service.StartMode
    if ($startupKey -eq 'Auto' -and $Service.Delayed) { $startupKey = 'AutoDelayed' }

    $state    = [string]$Service.State
    $stateKey = if ($state -like '*Pending') { 'Pending' } else { $state }

    $serviceType = [string]$Service.ServiceType
    $isDriver = $serviceType -eq 'Kernel Driver' -or
                $serviceType -eq 'File System Driver' -or
                $serviceType -eq 'Adapter' -or
                $serviceType -eq 'Recognizer Driver'

    $row = [SvcMgr.SvcRow]::new()
    $row.Name        = [string]$Service.Name
    $row.DisplayName = [string]$Service.DisplayName
    $row.StateKey    = $stateKey
    $row.State       = if ($script:StateText.ContainsKey($state)) { $script:StateText[$state] } else { $state }
    $row.StartupKey  = $startupKey
    $row.StartupType = if ($script:StartupText.ContainsKey($startupKey)) { $script:StartupText[$startupKey] } else { $startupKey }
    $row.Account     = [string]$Service.LogOn
    $row.Path        = [string]$Service.Path
    $row.Description = [string]$Service.Description
    $row.AcceptStop  = [bool]$Service.AcceptStop
    $row.ProcessId   = [uint32]$Service.ProcessId
    $row.ProcessName = [string]$Service.ProcessName
    $row.IsDriver    = $isDriver
    $row.Search      = (ConvertTo-FoldedText ('{0} {1} {2} {3} {4} {5} {6}' -f `
                        $row.Name, $row.DisplayName, $row.Description, $row.Account,
                        $row.Path, $row.ProcessName, $row.StartupType)).ToLowerInvariant()
    $row
}

# Display names of the running dependents, deepest first - the same order the worker stops them in.
function Get-RunningDependentNames {
    param([string]$Name)

    $result = New-Object System.Collections.ArrayList
    $seen   = @{}
    $walk = $null
    $walk = {
        param($ServiceName, $Result, $Seen)
        $service = $null
        try { $service = Get-Service -Name $ServiceName -ErrorAction Stop } catch { return }
        foreach ($dependent in @($service.DependentServices)) {
            if ($dependent.Status -eq 'Stopped') { continue }
            if ($Seen.ContainsKey($dependent.ServiceName)) { continue }
            $Seen[$dependent.ServiceName] = $true
            & $walk $dependent.ServiceName $Result $Seen
            [void]$Result.Add(('{0} ({1})' -f $dependent.DisplayName, $dependent.ServiceName))
        }
    }
    & $walk $Name $result $seen
    $result
}

function Update-Counts {
    $total   = $script:Rows.Count
    $shown   = $script:UI.ServiceGrid.Items.Count
    $running = 0
    foreach ($row in $script:Rows) { if ($row.StateKey -eq 'Running') { $running++ } }
    $script:UI.StatusLeft.Text = 'Showing {0} of {1}   |   Running: {2}' -f $shown, $total, $running
}

function Update-Filter {
    $script:View.Refresh()
    Update-Counts
}

function Update-Details {
    $ui   = $script:UI
    $row  = $ui.ServiceGrid.SelectedItem
    $has  = $null -ne $row
    $idle = -not $script:Busy

    if ($has) {
        $process = if ($row.ProcessId -gt 0) { '{0} ({1})' -f $row.ProcessId, $row.ProcessName } else { '-' }
        $kind    = if ($row.IsDriver) { 'driver' } else { 'service' }
        $ui.DetName.Text = $row.DisplayName
        $ui.DetDesc.Text = if ($row.Description) { $row.Description } else { 'No description.' }
        $ui.DetMeta.Text = 'Service name: {0}   |   Account: {1}   |   PID: {2}   |   {3}' -f $row.Name, $row.Account, $process, $kind
        $ui.DetPath.Text = $row.Path
        $ui.DetPath.ToolTip = $row.Path
    }
    else {
        $ui.DetName.Text = 'Select a service from the list'
        $ui.DetDesc.Text = ''
        $ui.DetMeta.Text = ''
        $ui.DetPath.Text = ''
        $ui.DetPath.ToolTip = $null
    }

    $ui.BtnStart.IsEnabled   = $idle -and $has -and ($row.StateKey -eq 'Stopped' -or $row.StateKey -eq 'Paused') -and ($row.StartupKey -ne 'Disabled')
    $ui.BtnStop.IsEnabled    = $idle -and $has -and ($row.StateKey -eq 'Running' -or $row.StateKey -eq 'Paused') -and $row.AcceptStop
    $ui.BtnRestart.IsEnabled = $idle -and $has -and ($row.StateKey -eq 'Running') -and $row.AcceptStop

    foreach ($radio in $ui.StartupRadios) {
        $radio.IsEnabled = $idle -and $has
        $radio.IsChecked = $has -and ([string]$radio.Tag -eq $row.StartupKey)
    }
}

function Set-Busy {
    param([bool]$Busy, [string]$Text)
    $script:Busy = $Busy
    $script:UI.Progress.Visibility  = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $script:UI.BtnRefresh.IsEnabled = -not $Busy
    if ($Text) { Set-Status $Text 'Busy' }
    Update-Details
}

# --- loading the list ----------------------------------------------------------------
$script:OnListDone = {
    param($Result, $ErrorText, $Cancelled)

    Set-Busy $false
    if ($ErrorText) {
        Set-Status ('Could not load the service list: ' + $ErrorText) 'Error'
        return
    }

    $ui   = $script:UI
    $keep = $script:PendingSelect
    $script:PendingSelect = $null
    if (-not $keep -and $ui.ServiceGrid.SelectedItem) { $keep = $ui.ServiceGrid.SelectedItem.Name }

    $script:Rows.Clear()
    foreach ($service in @($Result | Sort-Object DisplayName)) {
        $script:Rows.Add((ConvertTo-SvcRow $service))
    }
    Update-Counts

    if ($keep) {
        $item = $null
        foreach ($row in $script:Rows) { if ($row.Name -eq $keep) { $item = $row; break } }
        if ($item -and $ui.ServiceGrid.Items.Contains($item)) {
            $ui.ServiceGrid.SelectedItem = $item
            $ui.ServiceGrid.UpdateLayout()
            $ui.ServiceGrid.ScrollIntoView($item)
        }
    }

    if ($script:PendingStatus) {
        Set-Status $script:PendingStatus.Text $script:PendingStatus.Kind
        $script:PendingStatus = $null
    }
    else {
        Set-Status ('Refreshed at ' + (Get-Date -Format 'HH:mm:ss')) 'Info'
    }
}

function Update-ServiceList {
    param([string]$Select)
    if ($script:Busy) { return }
    if ($Select) { $script:PendingSelect = $Select }
    Set-Busy $true 'Loading services...'
    [void](Start-Background -Work $script:Work.List -OnDone $script:OnListDone)
}

# --- actions: start / stop / restart / startup type ------------------------------------
$script:OnActionDone = {
    param($Result, $ErrorText, $Cancelled)

    Set-Busy $false
    $context = $script:Ctx
    $script:Ctx = $null

    if ($Cancelled) {
        $script:PendingStatus = @{ Text = 'Operation cancelled.'; Kind = 'Info' }
    }
    elseif ($ErrorText) {
        $script:PendingStatus = @{ Text = ($context.ErrTitle + ': ' + $ErrorText); Kind = 'Error' }
        [void](Show-Dialog -Title $context.ErrTitle -Message $ErrorText -Kind Error)
    }
    else {
        $script:PendingStatus = @{ Text = $context.OkText; Kind = 'Ok' }
    }

    if ($context -and $context.Name) { Update-ServiceList -Select $context.Name }
    else { Update-ServiceList }
}

function Invoke-ServiceAction {
    param([ValidateSet('Start', 'Stop', 'Restart')][string]$Action)

    $row = $script:UI.ServiceGrid.SelectedItem
    if (-not $row -or $script:Busy) { return }

    $name    = $row.Name
    $display = $row.DisplayName

    if ($Action -ne 'Start') {
        $dependents = @(Get-RunningDependentNames -Name $name)
        $verb = if ($Action -eq 'Stop') { 'Stop' } else { 'Restart' }
        $message = "{0} service '{1}' ({2})?" -f $verb, $display, $name

        if ($dependents.Count -gt 0) {
            if ($Action -eq 'Stop') {
                $message += "`n`nThe following dependent services will be stopped as well:`n- " + ($dependents -join "`n- ")
            }
            else {
                $message += "`n`nThe following dependent services will be stopped and started again afterwards:`n- " + ($dependents -join "`n- ")
            }
        }
        if ($row.IsDriver) {
            $message += "`n`nWarning: this entry is a device driver, not a user-mode service."
        }

        $yesText = if ($Action -eq 'Stop') { 'Stop' } else { 'Restart' }
        if (-not (Show-Dialog -Title 'Confirm' -Message $message -Kind Confirm -YesText $yesText)) { return }
    }

    $progress = @{ Start = 'Starting'; Stop = 'Stopping'; Restart = 'Restarting' }[$Action]
    $done     = @{ Start = 'Started'; Stop = 'Stopped'; Restart = 'Restarted' }[$Action]

    $script:Ctx = @{
        Name     = $name
        OkText   = ('{0}: {1}' -f $done, $display)
        ErrTitle = ('Error - {0}' -f $display)
    }

    Set-Busy $true ("{0} '{1}'...   (Esc to cancel)" -f $progress, $display)
    $started = Start-Background -Work $script:Work.Action `
                               -Arguments @($Action, $name, $script:OperationTimeoutSec) `
                               -Cancellable -OnDone $script:OnActionDone
    if (-not $started) { $script:Ctx = $null }
}

function Set-StartupType {
    param([string]$Key)

    $row = $script:UI.ServiceGrid.SelectedItem
    if (-not $row -or $script:Busy -or -not $script:ScMode.ContainsKey($Key)) { return }
    if ($row.StartupKey -eq $Key) { return }

    $label       = $script:StartupText[$Key]
    $bootDriver  = $row.IsDriver -and ($row.StartupKey -eq 'Boot' -or $row.StartupKey -eq 'System')

    if ($Key -eq 'Disabled' -or $bootDriver) {
        $message = "Change the startup type of '{0}' ({1}) from {2} to {3}?" -f $row.DisplayName, $row.Name, $row.StartupType, $label
        if ($row.IsDriver) {
            $message += "`n`nWarning: this entry is a device driver."
            if ($bootDriver) {
                $message += (" It is a {0}-start driver - changing its startup type can prevent Windows from booting." -f $row.StartupKey)
            }
        }
        if ($Key -eq 'Disabled') {
            $message += "`n`nThe service cannot be started until the startup type is changed back."
        }
        $yesText = if ($Key -eq 'Disabled') { 'Disable' } else { 'Change' }
        if (-not (Show-Dialog -Title 'Confirm' -Message $message -Kind Confirm -YesText $yesText)) {
            Update-Details   # restore the previously selected toggle
            return
        }
    }

    $script:Ctx = @{
        Name     = $row.Name
        OkText   = ("Startup type of '{0}' set to {1}." -f $row.DisplayName, $label)
        ErrTitle = ('Error - {0}' -f $row.DisplayName)
    }

    Set-Busy $true ("Changing the startup type of '{0}'..." -f $row.DisplayName)
    $started = Start-Background -Work $script:Work.Startup -Arguments @($row.Name, $script:ScMode[$Key]) -OnDone $script:OnActionDone
    if (-not $started) { $script:Ctx = $null }
}

# =====================================================================================
# 6. Event wiring
# =====================================================================================
$ui = $script:UI

# title bar
$ui.BtnMin.Add_Click({ $script:Win.WindowState = [System.Windows.WindowState]::Minimized })
$ui.BtnMax.Add_Click({
    if ($script:Win.WindowState -eq [System.Windows.WindowState]::Maximized) {
        $script:Win.WindowState = [System.Windows.WindowState]::Normal
    }
    else {
        $script:Win.WindowState = [System.Windows.WindowState]::Maximized
    }
})
$ui.BtnClose.Add_Click({ $script:Win.Close() })

# a frameless window overflows the screen by the resize border when maximized - compensate with a margin
$script:Win.Add_StateChanged({
    $chrome = [System.Windows.Shell.WindowChrome]::GetWindowChrome($script:Win)
    if ($script:Win.WindowState -eq [System.Windows.WindowState]::Maximized) {
        $border = [System.Windows.SystemParameters]::WindowResizeBorderThickness
        $script:UI.RootBorder.Margin = $border
        $script:UI.BtnMax.Content    = [string][char]0xE923
        try { $chrome.CaptionHeight = 41 + $border.Top } catch { }
    }
    else {
        $script:UI.RootBorder.Margin = New-Object System.Windows.Thickness 0
        $script:UI.BtnMax.Content    = [string][char]0xE922
        try { $chrome.CaptionHeight = 41 } catch { }
    }
})

# search and filters
$ui.SearchBox.Add_TextChanged({
    $text    = $script:UI.SearchBox.Text
    $hasText = [bool]$text
    $script:UI.SearchHint.Visibility = if ($hasText) { 'Collapsed' } else { 'Visible' }
    $script:UI.BtnClear.Visibility   = if ($hasText) { 'Visible' } else { 'Collapsed' }

    $terms = @()
    foreach ($term in ($text -split '\s+')) {
        if ($term) { $terms += (ConvertTo-FoldedText $term).ToLowerInvariant() }
    }
    $script:Terms = $terms
    Update-Filter
})
$ui.BtnClear.Add_Click({ $script:UI.SearchBox.Clear(); [void]$script:UI.SearchBox.Focus() })
$ui.FilterAll.Add_Checked({     $script:StateFilter = 'All';     Update-Filter })
$ui.FilterRunning.Add_Checked({ $script:StateFilter = 'Running'; Update-Filter })
$ui.FilterStopped.Add_Checked({ $script:StateFilter = 'Stopped'; Update-Filter })

# list and actions
$ui.ServiceGrid.Add_SelectionChanged({ Update-Details })
$ui.BtnRefresh.Add_Click({ Update-ServiceList })
$ui.BtnStart.Add_Click({   Invoke-ServiceAction 'Start' })
$ui.BtnStop.Add_Click({    Invoke-ServiceAction 'Stop' })
$ui.BtnRestart.Add_Click({ Invoke-ServiceAction 'Restart' })
foreach ($radio in $ui.StartupRadios) {
    $radio.Add_Click({ param($sender) Set-StartupType ([string]$sender.Tag) })
}

# keyboard shortcuts
$script:Win.Add_PreviewKeyDown({
    param($sender, $eventArgs)

    if ($eventArgs.Key -eq [System.Windows.Input.Key]::F5) {
        Update-ServiceList
        $eventArgs.Handled = $true
        return
    }

    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::F -and $ctrl) {
        [void]$script:UI.SearchBox.Focus()
        $script:UI.SearchBox.SelectAll()
        $eventArgs.Handled = $true
        return
    }

    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) {
        if ($script:Busy) {
            Request-Cancel
            $eventArgs.Handled = $true
        }
        elseif ($script:UI.SearchBox.Text) {
            $script:UI.SearchBox.Clear()
            $eventArgs.Handled = $true
        }
    }
})

# safety net: an unhandled exception must not kill the application
$script:Win.Dispatcher.Add_UnhandledException({
    param($sender, $eventArgs)
    $eventArgs.Handled = $true
    try {
        Set-Busy $false
        Set-Status ('Error: ' + $eventArgs.Exception.Message) 'Error'
    }
    catch { }
})

# clean shutdown: cancel a running operation and release the runspace pool
$script:Win.Add_Closing({
    Request-Cancel
    $script:Timer.Stop()
    $job = $script:Job
    $script:Job = $null
    if ($job) {
        try { if ($job.Cts) { $job.Cts.Cancel() } } catch { }
        try { $job.PS.Stop() } catch { }
        try { $job.PS.Dispose() } catch { }
    }
})

$script:Win.Add_Loaded({
    Update-Details
    Update-ServiceList
})

# =====================================================================================
# 7. Start
# =====================================================================================
Write-Host 'Opening the window...' -ForegroundColor Green
try {
    [void]$script:Win.ShowDialog()
    Write-Host 'Window closed.' -ForegroundColor Green
}
catch {
    Write-Host ('EXCEPTION: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    [void][System.Windows.MessageBox]::Show($_.Exception.Message, 'Service Manager', 'OK', 'Error')
    [void](Read-Host 'Press Enter to close')
}
finally {
    if ($script:Pool) {
        try { $script:Pool.Close() } catch { }
        try { $script:Pool.Dispose() } catch { }
        $script:Pool = $null
    }
}
