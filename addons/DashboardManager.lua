local cloneref = (cloneref or clonereference or function(instance: any)
    return instance
end)

local HttpService: HttpService = cloneref(game:GetService("HttpService"))
local Players: Players = cloneref(game:GetService("Players"))
local RunService: RunService = cloneref(game:GetService("RunService"))
local TweenService: TweenService = cloneref(game:GetService("TweenService"))
local UserInputService: UserInputService = cloneref(game:GetService("UserInputService"))
local SoundService: SoundService = cloneref(game:GetService("SoundService"))
local LocalizationService: LocalizationService = cloneref(game:GetService("LocalizationService"))
local MarketplaceService: MarketplaceService = cloneref(game:GetService("MarketplaceService"))

local LocalPlayer: Player = Players.LocalPlayer

--// DashboardManager \\--
local DashboardManager = {
    Library = nil,
    Dashboard = nil,
    AppliedToTab = false,
}

function DashboardManager:SetLibrary(Library)
    DashboardManager.Library = Library
end

--// Helpers \\--
local function Trim(Text: string)
    return Text:match("^%s*(.-)%s*$")
end

--// Supports a plain invite code, a full discord.gg / discord.com link or a markdown link
local function ExtractDiscordInviteCode(Invite: any): string
    Invite = tostring(Invite or "")
    if Trim(Invite) == "" then
        return ""
    end

    local Code = Invite:match("discord%.gg/([%w%-]+)") or Invite:match("discord%.com/invite/([%w%-]+)")
    if Code then
        return Code
    end

    return Invite:match("^[%s%[%(]*([%w%-]+)") or ""
end

local function GetGreeting(Greetings: { [string]: string }): string
    local Hour = os.date("*t").hour

    if Hour >= 4 and Hour < 12 then
        return Greetings.Morning or "Good Morning"
    elseif Hour >= 12 and Hour < 19 then
        return Greetings.Afternoon or "How's Your Day Going?"
    elseif Hour >= 19 and Hour <= 23 then
        return Greetings.Evening or "Sweet Dreams"
    end

    return Greetings.Night or "You should be asleep"
end

local function GetElapsed(StartedAt: number): string
    local Elapsed = math.max(0, (os.clock() - StartedAt))

    if Elapsed < 60 then
        return tostring(math.floor(Elapsed)) .. "s"
    elseif Elapsed < 3600 then
        return tostring(math.floor(Elapsed / 60)) .. "m"
    end

    return tostring(math.floor(Elapsed / 3600)) .. "h"
end

local function SetText(Object: any, Text: string)
    if Object and Object.Parent then
        Object.Text = tostring(Text or "")
    end
end

--// Music helpers \\--
local function FormatTime(Seconds: number?): string
    Seconds = math.max(0, math.floor(tonumber(Seconds) or 0))

    local Hours = math.floor(Seconds / 3600)
    local Minutes = math.floor((Seconds % 3600) / 60)
    local SecondsLeft = Seconds % 60

    if Hours > 0 then
        return string.format("%d:%02d:%02d", Hours, Minutes, SecondsLeft)
    end

    return string.format("%d:%02d", Minutes, SecondsLeft)
end

--// Accepts a raw asset id, rbxassetid://..., a roblox.com link or a workspace file name \\--
local function ParseMusicSource(Raw: any)
    local Text = Trim(tostring(Raw or ""))
    if Text == "" then
        return nil
    end

    local Lowered = Text:lower()
    local AssetId = Lowered:match("^rbxassetid://(%d+)$")
        or Lowered:match("^rbxasset://(%d+)$")
        or Lowered:match("^%d+$")
        or Lowered:match("roblox%.com/library/(%d+)")
        or Lowered:match("roblox%.com/catalog/(%d+)")
        or Lowered:match("roblox%.com/asset/%?id=(%d+)")

    if AssetId then
        local Id = tonumber(AssetId)
        if Id and Id > 0 then
            return { Type = "Asset", Id = Id, SoundId = "rbxassetid://" .. Id }
        end
        return nil
    end

    if Lowered:match("%.mp3$") or Lowered:match("%.ogg$") or Lowered:match("%.wav$") then
        local Name = Trim((Text:gsub("\\", "/")))
        if Name ~= "" then
            return { Type = "File", FileName = Name }
        end
    end

    return nil
end

--// Lists playable audio files inside the executor workspace folder \\--
local function ScanWorkspaceAudioFiles(): { string }
    local Results = {}
    if typeof(listfiles) ~= "function" then
        return Results
    end

    local Seen = {}
    for _, Prefix in { "", ".", "./" } do
        local Ok, Files = pcall(listfiles, Prefix)
        if Ok and typeof(Files) == "table" then
            for _, RawPath in Files do
                local Path = tostring(RawPath):gsub("^%./", ""):gsub("^workspace/", "")
                local Lowered = Path:lower()

                if Lowered:match("%.mp3$") or Lowered:match("%.ogg$") or Lowered:match("%.wav$") then
                    if not Path:match("/$") and not Seen[Path] then
                        Seen[Path] = true
                        table.insert(Results, Path)
                    end
                end
            end
        end

        if #Results > 0 then
            break
        end
    end

    table.sort(Results)
    return Results
end

--// Defaults \\--
local Defaults = {
    Name = "Dashboard",
    Title = nil,
    Icon = "layout-dashboard",
    Description = nil,
    Order = nil,

    DetailsText = "Details And Info",
    DetailsIcon = "layout-grid",
    ShowDetailsSegment = true,

    MusicText = "Music",
    MusicIcon = "music",
    ShowMusicSegment = true,
    DefaultVolume = 50,
    DefaultSpeed = 1,

    DiscordInvite = "",
    SupportedExecutors = {},
    UnsupportedExecutors = {},

    Greetings = {
        Morning = "Good Morning",
        Afternoon = "How's Your Day Going?",
        Evening = "Sweet Dreams",
        Night = "You should be asleep",
    },
}

--// UI builders (theme aware via Library registry) \\--
local function MakeCorner(Library, Parent: any, Radius: number?, Track: boolean?): UICorner
    --// Safety: also accept MakeCorner(Parent, Radius) calls and guard against swapped arguments
    --// (prevents "invalid argument #3 (Instance expected, got number)" crashes)
    if typeof(Parent) ~= "Instance" and typeof(Library) == "Instance" then
        Library, Parent, Radius = nil, Library, Parent
    end

    if typeof(Radius) ~= "number" then
        Radius = 6
    end

    local Corner = Instance.new("UICorner")
    Corner.CornerRadius = UDim.new(0, Radius)
    Corner.Parent = Parent

    --// Tracked corners follow Window:SetCornerRadius updates like native library elements
    if Track and Library and typeof(Library.Corners) == "table" then
        table.insert(Library.Corners, Corner)
    end

    return Corner
end

local function MakeStroke(Library, Parent: GuiObject): UIStroke
    local Stroke = Instance.new("UIStroke")
    Stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    Stroke.Thickness = 1
    Stroke.Parent = Parent

    Library:AddToRegistry(Stroke, { Color = "OutlineColor" })
    Stroke.Color = Library.Scheme.OutlineColor
    return Stroke
end

local function MakeText(
    Library,
    Parent: GuiObject,
    Text: string,
    Size: number,
    Bold: boolean?,
    Transparency: number?
): TextLabel
    local Label = Instance.new("TextLabel")
    Label.BackgroundTransparency = 1
    Label.Size = UDim2.new(1, 0, 0, Size + 6)
    Label.Text = tostring(Text or "")
    Label.TextSize = Size
    Label.TextTransparency = Transparency or 0
    Label.TextXAlignment = Enum.TextXAlignment.Left
    Label.TextYAlignment = Enum.TextYAlignment.Center
    Label.TextTruncate = Enum.TextTruncate.AtEnd
    Label.Parent = Parent

    if Bold == true then
        --// Bold labels are drawn fully opaque, regular ones rely on the transparency parameter
        Label.TextTransparency = 0
    end

    Library:AddToRegistry(Label, { TextColor3 = "FontColor", FontFace = "Font" })

    Label.TextColor3 = Library.Scheme.FontColor
    Label.FontFace = Library.Scheme.Font
    return Label
end

local function MakePanel(Library, Parent: GuiObject, Size: UDim2, Position: UDim2?): Frame
    local Panel = Instance.new("Frame")
    Panel.BackgroundColor3 = Library.Scheme.MainColor
    Panel.BorderSizePixel = 0
    Panel.ClipsDescendants = true
    Panel.Size = Size
    Panel.Position = Position or UDim2.fromOffset(0, 0)
    Panel.Parent = Parent

    Library:AddToRegistry(Panel, { BackgroundColor3 = "MainColor" })
    MakeCorner(Library, Panel, Library.CornerRadius, true)
    MakeStroke(Library, Panel)
    return Panel
end

--// Creates a lib icon (font or image) that auto updates with the theme
local function MakeIcon(Library, Parent: GuiObject, IconName: string, Size: number, SchemeName: string?): GuiObject
    local CustomIcon = Library:GetCustomIcon(IconName)

    local Icon = Library:CreateIcon(CustomIcon, {
        Size = UDim2.fromOffset(Size, Size),
        ImageColor3 = SchemeName or "FontColor",
        Parent = Parent,
    })

    return Icon
end

--// Repaints an icon and keeps the theme registry in sync
local function SetIconColorScheme(Library, Icon: GuiObject, SchemeName: string)
    local IsText = Icon:IsA("TextLabel") or Icon:IsA("TextButton")
    local Property = IsText and "TextColor3" or "ImageColor3"
    local Target: any = Icon

    Target[Property] = Library.Scheme[SchemeName]
    if Library.Registry[Icon] then
        Library.Registry[Icon][Property] = SchemeName
    end
end

--// Small stat box used across cards; returns the value label for live updates
local function MakeStat(
    Library,
    Parent: GuiObject,
    Title: string,
    Value: string,
    X: number,
    Y: number,
    W: number
): TextLabel
    local Stat = Instance.new("Frame")
    Stat.BackgroundColor3 = Library.Scheme.BackgroundColor
    Stat.BackgroundTransparency = 0.25
    Stat.BorderSizePixel = 0
    Stat.Size = UDim2.new(W, -6, 0, 42)
    Stat.Position = UDim2.new(X, 3, 0, Y)
    Stat.Parent = Parent

    Library:AddToRegistry(Stat, { BackgroundColor3 = "BackgroundColor" })
    MakeCorner(Library, Stat, 4)

    local TitleLabel = MakeText(Library, Stat, Title, 10, true, 0.13)
    TitleLabel.Position = UDim2.fromOffset(10, 7)
    TitleLabel.Size = UDim2.new(1, -20, 0, 13)

    local ValueLabel = MakeText(Library, Stat, Value, 10, false, 0.35)
    ValueLabel.Position = UDim2.fromOffset(10, 21)
    ValueLabel.Size = UDim2.new(1, -20, 0, 13)

    return ValueLabel
end

--// Icon creation with a text glyph fallback so unknown icon names never break the UI
local function SafeIcon(
    Library,
    Parent: GuiObject,
    IconName: string?,
    Size: number,
    SchemeName: string?,
    FallbackText: string?
): GuiObject
    if IconName then
        local Ok, Icon = pcall(function()
            return MakeIcon(Library, Parent, IconName, Size, SchemeName)
        end)
        if Ok and typeof(Icon) == "Instance" then
            Icon.Parent = Parent
            return Icon
        end
    end

    local Label = Instance.new("TextLabel")
    Label.BackgroundTransparency = 1
    Label.Size = UDim2.fromOffset(Size + 8, Size)
    Label.Text = tostring(FallbackText or IconName or "?")
    Label.TextSize = math.max(8, Size - 4)
    Label.FontFace = Library.Scheme.Font
    Label.TextColor3 = Library.Scheme[SchemeName or "FontColor"] or Library.Scheme.FontColor
    Label.Parent = Parent
    Library:AddToRegistry(Label, { TextColor3 = SchemeName or "FontColor", FontFace = "Font" })
    return Label
end

--// Horizontal slider (volume / speed) with click + drag support
local function MakeSlider(Library, Parent: GuiObject, Settings: any, Connections: { any }?)
    local Min = tonumber(Settings.Min) or 0
    local Max = tonumber(Settings.Max) or 100
    local Step = tonumber(Settings.Step)
    local Default = tonumber(Settings.Default) or Min

    local Root = Instance.new("Frame")
    Root.BackgroundTransparency = 1
    Root.BorderSizePixel = 0
    Root.Size = UDim2.new(1, 0, 0, 44)
    Root.Parent = Parent

    local TitleLabel = MakeText(Library, Root, tostring(Settings.Title or ""), 10, true, 0.3)
    TitleLabel.Position = UDim2.fromOffset(0, 0)
    TitleLabel.Size = UDim2.new(1, -52, 0, 14)

    local ValueLabel = MakeText(Library, Root, "", 10, true, 0)
    ValueLabel.AnchorPoint = Vector2.new(1, 0)
    ValueLabel.Position = UDim2.new(1, 0, 0, 0)
    ValueLabel.Size = UDim2.fromOffset(48, 14)
    ValueLabel.TextXAlignment = Enum.TextXAlignment.Right
    Library:AddToRegistry(ValueLabel, { TextColor3 = "AccentColor", FontFace = "Font" })
    ValueLabel.TextColor3 = Library.Scheme.AccentColor

    local Track = Instance.new("TextButton")
    Track.Name = tostring(Settings.Title or "Slider") .. "Track"
    Track.BackgroundColor3 = Library.Scheme.BackgroundColor
    Track.BackgroundTransparency = 0.35
    Track.BorderSizePixel = 0
    Track.AutoButtonColor = false
    Track.Text = ""
    Track.Position = UDim2.fromOffset(0, 26)
    Track.Size = UDim2.new(1, 0, 0, 6)
    Track.Parent = Root
    Library:AddToRegistry(Track, { BackgroundColor3 = "BackgroundColor" })
    MakeCorner(Library, Track, 3)

    local Fill = Instance.new("Frame")
    Fill.BackgroundColor3 = Library.Scheme.AccentColor
    Fill.BorderSizePixel = 0
    Fill.Size = UDim2.fromScale(0, 1)
    Fill.Parent = Track
    Library:AddToRegistry(Fill, { BackgroundColor3 = "AccentColor" })
    MakeCorner(Library, Fill, 3)

    local Knob = Instance.new("Frame")
    Knob.AnchorPoint = Vector2.new(0.5, 0.5)
    Knob.BackgroundColor3 = Color3.new(1, 1, 1)
    Knob.BorderSizePixel = 0
    Knob.Position = UDim2.fromScale(0, 0.5)
    Knob.Size = UDim2.fromOffset(12, 12)
    Knob.Parent = Track
    MakeCorner(Library, Knob, 6)

    local Current = Default

    local function SetValue(Value: number, Silent: boolean?)
        if Step and Step > 0 then
            Value = math.floor(Value / Step + 0.5) * Step
        end
        Value = math.clamp(Value, Min, Max)
        Current = Value

        local Alpha = (Max - Min) > 0 and (Value - Min) / (Max - Min) or 0
        Fill.Size = UDim2.fromScale(Alpha, 1)
        Knob.Position = UDim2.new(Alpha, 0, 0.5, 0)
        ValueLabel.Text = Settings.Format and Settings.Format(Value) or tostring(Value)

        if not Silent and Settings.OnChange then
            Settings.OnChange(Value)
        end
    end

    local Dragging = false

    local function ApplyFromX(X: number)
        local Relative = math.clamp(X - Track.AbsolutePosition.X, 0, Track.AbsoluteSize.X)
        local Alpha = Relative / math.max(Track.AbsoluteSize.X, 1)
        SetValue(Min + (Max - Min) * Alpha)
    end

    Track.InputBegan:Connect(function(Input)
        if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
            Dragging = true
            ApplyFromX(Input.Position.X)
        end
    end)

    Track.InputEnded:Connect(function(Input)
        if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
            Dragging = false
        end
    end)

    local ChangedConnection = UserInputService.InputChanged:Connect(function(Input)
        if Dragging
            and (Input.UserInputType == Enum.UserInputType.MouseMovement or Input.UserInputType == Enum.UserInputType.Touch)
        then
            ApplyFromX(Input.Position.X)
        end
    end)

    local ReleasedConnection = UserInputService.InputEnded:Connect(function(Input)
        if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
            Dragging = false
        end
    end)

    if Connections then
        table.insert(Connections, ChangedConnection)
        table.insert(Connections, ReleasedConnection)
    end

    SetValue(Default, true)

    return {
        Root = Root,
        SetValue = SetValue,
        GetValue = function()
            return Current
        end,
    }
end

--// Music player page: play / pause / stop, prev / next, seek bar, volume & speed (pitch)
--// sliders, playlist fed by Roblox asset ids or .mp3 files from the executor workspace
--// folder, with loop (repeat playlist) and shuffle support
local function CreateMusicPlayerPage(Library: any, Parent: GuiObject, Options: any): (Frame, any)
    Options = Options or {}

    local Connections = {}

    local Page = Instance.new("Frame")
    Page.Name = "MusicPlayer"
    Page.BackgroundTransparency = 1
    Page.BorderSizePixel = 0
    Page.Size = UDim2.new(1, 0, 0, 0)
    Page.AutomaticSize = Enum.AutomaticSize.Y
    Page.ClipsDescendants = false
    Page.LayoutOrder = 4
    Page.Visible = false
    Page.Parent = Parent

    local PageLayout = Instance.new("UIListLayout")
    PageLayout.SortOrder = Enum.SortOrder.LayoutOrder
    PageLayout.Padding = UDim.new(0, 10)
    PageLayout.Parent = Page

    --// Player state
    local Playlist = {}
    local CurrentIndex = nil
    local Looping = false
    local Shuffling = false
    local PausedManually = false
    local DraggingSeek = false
    local GuardAdvance = false
    local EntryFrames = {}

    --// Forward declared so the button closures can be wired before the logic exists
    local PlayIndex, Advance, Previous, TogglePlayPause, StopPlayback
    local RefreshPlaylist, TryAddSource, RemoveAt, ClearPlaylist
    local UpdatePlayPauseIcon, UpdateStatus, UpdateSeek, SyncAll, SetToggleVisual
    local LoopButton, ShuffleButton, PlayIcon, PauseIcon, VolumeSlider, SpeedSlider

    --// The sound lives in SoundService so it keeps playing locally
    local Sound = Instance.new("Sound")
    Sound.Name = "FALLENS_DashboardMusic"
    Sound.Volume = math.clamp((tonumber(Options.DefaultVolume) or 50) / 100, 0, 1)
    Sound.PlaybackSpeed = math.clamp(tonumber(Options.DefaultSpeed) or 1, 0.25, 3)
    Sound.Parent = SoundService

    local function Notify(Title: string, Description: string, Duration: number?)
        if Options.Notify then
            Options.Notify({ Title = Title, Description = Description, Time = Duration or 4 })
        end
    end

    --// Player card
    local PlayerCard = MakePanel(Library, Page, UDim2.new(1, 0, 0, 208))
    PlayerCard.LayoutOrder = 1

    local PlayerLayout = Instance.new("UIListLayout")
    PlayerLayout.SortOrder = Enum.SortOrder.LayoutOrder
    PlayerLayout.Padding = UDim.new(0, 8)
    PlayerLayout.Parent = PlayerCard

    local PlayerPadding = Instance.new("UIPadding")
    PlayerPadding.PaddingTop = UDim.new(0, 12)
    PlayerPadding.PaddingBottom = UDim.new(0, 12)
    PlayerPadding.PaddingLeft = UDim.new(0, 14)
    PlayerPadding.PaddingRight = UDim.new(0, 14)
    PlayerPadding.Parent = PlayerCard

    local HeaderRow = Instance.new("Frame")
    HeaderRow.BackgroundTransparency = 1
    HeaderRow.Size = UDim2.new(1, 0, 0, 18)
    HeaderRow.LayoutOrder = 1
    HeaderRow.Parent = PlayerCard

    local PlayerTitle = MakeText(Library, HeaderRow, "Music Player", 15, true, 0)
    PlayerTitle.Size = UDim2.new(1, -110, 1, 0)

    local StatusLabel = MakeText(Library, HeaderRow, "Stopped", 10, true, 0.35)
    StatusLabel.AnchorPoint = Vector2.new(1, 0.5)
    StatusLabel.Position = UDim2.new(1, 0, 0.5, 0)
    StatusLabel.Size = UDim2.fromOffset(100, 14)
    StatusLabel.TextXAlignment = Enum.TextXAlignment.Right

    local SongRow = Instance.new("Frame")
    SongRow.BackgroundTransparency = 1
    SongRow.Size = UDim2.new(1, 0, 0, 34)
    SongRow.LayoutOrder = 2
    SongRow.Parent = PlayerCard

    local SongIcon = SafeIcon(Library, SongRow, "music", 22, "AccentColor", "M")
    SongIcon.AnchorPoint = Vector2.new(0, 0.5)
    SongIcon.Position = UDim2.new(0, 0, 0.5, 0)

    local SongTitle = MakeText(Library, SongRow, "Nothing playing", 14, true, 0)
    SongTitle.Position = UDim2.fromOffset(30, 1)
    SongTitle.Size = UDim2.new(1, -30, 0, 18)

    local SongSub = MakeText(Library, SongRow, "Add a song from the playlist below", 10, false, 0.35)
    SongSub.Position = UDim2.fromOffset(30, 19)
    SongSub.Size = UDim2.new(1, -30, 0, 14)

    --// Seek bar: click or drag to jump anywhere in the song
    local SeekRow = Instance.new("Frame")
    SeekRow.BackgroundTransparency = 1
    SeekRow.Size = UDim2.new(1, 0, 0, 16)
    SeekRow.LayoutOrder = 3
    SeekRow.Parent = PlayerCard

    local ElapsedLabel = MakeText(Library, SeekRow, "0:00", 10, true, 0.35)
    ElapsedLabel.Size = UDim2.fromOffset(34, 16)

    local DurationLabel = MakeText(Library, SeekRow, "0:00", 10, true, 0.35)
    DurationLabel.AnchorPoint = Vector2.new(1, 0.5)
    DurationLabel.Position = UDim2.new(1, 0, 0.5, 0)
    DurationLabel.Size = UDim2.fromOffset(34, 16)
    DurationLabel.TextXAlignment = Enum.TextXAlignment.Right

    local SeekTrack = Instance.new("TextButton")
    SeekTrack.Name = "SeekBar"
    SeekTrack.BackgroundColor3 = Library.Scheme.BackgroundColor
    SeekTrack.BackgroundTransparency = 0.35
    SeekTrack.BorderSizePixel = 0
    SeekTrack.AutoButtonColor = false
    SeekTrack.Text = ""
    SeekTrack.AnchorPoint = Vector2.new(0, 0.5)
    SeekTrack.Position = UDim2.new(0, 40, 0.5, 0)
    SeekTrack.Size = UDim2.new(1, -80, 0, 6)
    SeekTrack.Parent = SeekRow
    Library:AddToRegistry(SeekTrack, { BackgroundColor3 = "BackgroundColor" })
    MakeCorner(Library, SeekTrack, 3)

    local SeekFill = Instance.new("Frame")
    SeekFill.BackgroundColor3 = Library.Scheme.AccentColor
    SeekFill.BorderSizePixel = 0
    SeekFill.Size = UDim2.fromScale(0, 1)
    SeekFill.Parent = SeekTrack
    Library:AddToRegistry(SeekFill, { BackgroundColor3 = "AccentColor" })
    MakeCorner(Library, SeekFill, 3)

    local SeekKnob = Instance.new("Frame")
    SeekKnob.AnchorPoint = Vector2.new(0.5, 0.5)
    SeekKnob.BackgroundColor3 = Color3.new(1, 1, 1)
    SeekKnob.BorderSizePixel = 0
    SeekKnob.Position = UDim2.fromScale(0, 0.5)
    SeekKnob.Size = UDim2.fromOffset(12, 12)
    SeekKnob.Parent = SeekTrack
    MakeCorner(Library, SeekKnob, 6)

    local function SetSeekVisual(Alpha: number)
        local Clamped = math.clamp(Alpha, 0, 1)
        SeekFill.Size = UDim2.fromScale(Clamped, 1)
        SeekKnob.Position = UDim2.new(Clamped, 0, 0.5, 0)
    end

    local function SeekFromX(X: number)
        local Relative = math.clamp(X - SeekTrack.AbsolutePosition.X, 0, SeekTrack.AbsoluteSize.X)
        local Alpha = Relative / math.max(SeekTrack.AbsoluteSize.X, 1)
        local Length = Sound.TimeLength or 0

        if CurrentIndex and Length > 0 then
            Sound.TimePosition = Alpha * Length
        end
        SetSeekVisual(Alpha)
    end

    SeekTrack.InputBegan:Connect(function(Input)
        if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
            DraggingSeek = true
            SeekFromX(Input.Position.X)
        end
    end)

    SeekTrack.InputEnded:Connect(function(Input)
        if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
            DraggingSeek = false
        end
    end)

    table.insert(Connections, UserInputService.InputChanged:Connect(function(Input)
        if DraggingSeek
            and (Input.UserInputType == Enum.UserInputType.MouseMovement or Input.UserInputType == Enum.UserInputType.Touch)
        then
            SeekFromX(Input.Position.X)
        end
    end))

    table.insert(Connections, UserInputService.InputEnded:Connect(function(Input)
        if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
            DraggingSeek = false
        end
    end))

    --// Transport controls: prev, play/pause, stop, next, loop, shuffle
    local ControlsRow = Instance.new("Frame")
    ControlsRow.BackgroundTransparency = 1
    ControlsRow.Size = UDim2.new(1, 0, 0, 38)
    ControlsRow.LayoutOrder = 4
    ControlsRow.Parent = PlayerCard

    local ControlsLayout = Instance.new("UIListLayout")
    ControlsLayout.FillDirection = Enum.FillDirection.Horizontal
    ControlsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    ControlsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    ControlsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    ControlsLayout.Padding = UDim.new(0, 8)
    ControlsLayout.Parent = ControlsRow

    local function MakeIconButton(
        Parent: GuiObject,
        IconName: string?,
        Fallback: string,
        Width: number,
        Order: number,
        OnClick: any,
        Accent: boolean?
    )
        local Button = Instance.new("TextButton")
        Button.Name = tostring(IconName or "IconButton")
        Button.BorderSizePixel = 0
        Button.AutoButtonColor = false
        Button.Text = ""
        Button.Size = UDim2.fromOffset(Width, 34)
        Button.LayoutOrder = Order
        Button.Parent = Parent

        if Accent then
            Button.BackgroundColor3 = Library.Scheme.AccentColor
            Button.BackgroundTransparency = 0.15
            Library:AddToRegistry(Button, { BackgroundColor3 = "AccentColor" })
        else
            Button.BackgroundColor3 = Library.Scheme.BackgroundColor
            Button.BackgroundTransparency = 0.35
            Library:AddToRegistry(Button, { BackgroundColor3 = "BackgroundColor" })
        end

        MakeCorner(Library, Button, Library.CornerRadius, true)
        MakeStroke(Library, Button)

        local Info = { Root = Button, Icon = nil, Resting = Accent and 0.15 or 0.35 }

        if IconName then
            Info.Icon = SafeIcon(Library, Button, IconName, 18, Accent and "WhiteColor" or "FontColor", Fallback)
            Info.Icon.AnchorPoint = Vector2.new(0.5, 0.5)
            Info.Icon.Position = UDim2.fromScale(0.5, 0.5)
        end

        Button.MouseEnter:Connect(function()
            TweenService:Create(Button, Library.TweenInfo, { BackgroundTransparency = Accent and 0.05 or 0.15 }):Play()
        end)
        Button.MouseLeave:Connect(function()
            TweenService:Create(Button, Library.TweenInfo, { BackgroundTransparency = Info.Resting }):Play()
        end)
        Button.MouseButton1Click:Connect(OnClick)

        return Info
    end

    MakeIconButton(ControlsRow, "skip-back", "<<", 38, 1, function()
        Previous()
    end)

    local PlayPauseButton = MakeIconButton(ControlsRow, nil, "", 46, 2, function()
        TogglePlayPause()
    end, true)

    MakeIconButton(ControlsRow, "square", "[]", 38, 3, function()
        StopPlayback(false)
    end)

    MakeIconButton(ControlsRow, "skip-forward", ">>", 38, 4, function()
        Advance(1, false)
    end)

    PlayIcon = SafeIcon(Library, PlayPauseButton.Root, "play", 20, "WhiteColor", ">")
    PlayIcon.AnchorPoint = Vector2.new(0.5, 0.5)
    PlayIcon.Position = UDim2.fromScale(0.5, 0.5)

    PauseIcon = SafeIcon(Library, PlayPauseButton.Root, "pause", 20, "WhiteColor", "II")
    PauseIcon.AnchorPoint = Vector2.new(0.5, 0.5)
    PauseIcon.Position = UDim2.fromScale(0.5, 0.5)
    PauseIcon.Visible = false

    local ControlsSpacer = Instance.new("Frame")
    ControlsSpacer.BackgroundTransparency = 1
    ControlsSpacer.Size = UDim2.fromOffset(14, 34)
    ControlsSpacer.LayoutOrder = 5
    ControlsSpacer.Parent = ControlsRow

    LoopButton = MakeIconButton(ControlsRow, "repeat", "R", 34, 6, function()
        Looping = not Looping
        SetToggleVisual(LoopButton, Looping)
    end)

    ShuffleButton = MakeIconButton(ControlsRow, "shuffle", "S", 34, 7, function()
        Shuffling = not Shuffling
        SetToggleVisual(ShuffleButton, Shuffling)
    end)

    --// Volume & speed (pitch) sliders
    local SlidersRow = Instance.new("Frame")
    SlidersRow.BackgroundTransparency = 1
    SlidersRow.Size = UDim2.new(1, 0, 0, 46)
    SlidersRow.LayoutOrder = 5
    SlidersRow.Parent = PlayerCard

    local VolumeBox = Instance.new("Frame")
    VolumeBox.BackgroundTransparency = 1
    VolumeBox.Size = UDim2.new(0.5, -5, 1, 0)
    VolumeBox.Parent = SlidersRow

    local SpeedBox = Instance.new("Frame")
    SpeedBox.BackgroundTransparency = 1
    SpeedBox.Position = UDim2.new(0.5, 5, 0, 0)
    SpeedBox.Size = UDim2.new(0.5, -5, 1, 0)
    SpeedBox.Parent = SlidersRow

    VolumeSlider = MakeSlider(Library, VolumeBox, {
        Title = "Volume",
        Min = 0,
        Max = 100,
        Default = math.clamp(tonumber(Options.DefaultVolume) or 50, 0, 100),
        Step = 1,
        Format = function(Value)
            return tostring(math.floor(Value + 0.5)) .. "%"
        end,
        OnChange = function(Value)
            Sound.Volume = math.clamp(Value / 100, 0, 1)
        end,
    }, Connections)

    SpeedSlider = MakeSlider(Library, SpeedBox, {
        Title = "Speed / Pitch",
        Min = 0.25,
        Max = 3,
        Default = math.clamp(tonumber(Options.DefaultSpeed) or 1, 0.25, 3),
        Step = 0.05,
        Format = function(Value)
            return string.format("%.2fx", Value)
        end,
        OnChange = function(Value)
            Sound.PlaybackSpeed = math.clamp(Value, 0.25, 3)
        end,
    }, Connections)

    --// Playlist card
    local PlaylistCard = MakePanel(Library, Page, UDim2.new(1, 0, 0, 0))
    PlaylistCard.AutomaticSize = Enum.AutomaticSize.Y
    PlaylistCard.LayoutOrder = 2

    local PlaylistLayout = Instance.new("UIListLayout")
    PlaylistLayout.SortOrder = Enum.SortOrder.LayoutOrder
    PlaylistLayout.Padding = UDim.new(0, 8)
    PlaylistLayout.Parent = PlaylistCard

    local PlaylistPadding = Instance.new("UIPadding")
    PlaylistPadding.PaddingTop = UDim.new(0, 12)
    PlaylistPadding.PaddingBottom = UDim.new(0, 12)
    PlaylistPadding.PaddingLeft = UDim.new(0, 14)
    PlaylistPadding.PaddingRight = UDim.new(0, 14)
    PlaylistPadding.Parent = PlaylistCard

    local PlaylistHeaderRow = Instance.new("Frame")
    PlaylistHeaderRow.BackgroundTransparency = 1
    PlaylistHeaderRow.Size = UDim2.new(1, 0, 0, 20)
    PlaylistHeaderRow.LayoutOrder = 1
    PlaylistHeaderRow.Parent = PlaylistCard

    local PlaylistTitle = MakeText(Library, PlaylistHeaderRow, "Playlist", 14, true, 0)
    PlaylistTitle.Size = UDim2.new(1, -180, 1, 0)

    local CountLabel = MakeText(Library, PlaylistHeaderRow, "0 songs", 10, true, 0.35)
    CountLabel.AnchorPoint = Vector2.new(1, 0.5)
    CountLabel.Position = UDim2.new(1, -84, 0.5, 0)
    CountLabel.Size = UDim2.fromOffset(60, 14)
    CountLabel.TextXAlignment = Enum.TextXAlignment.Right

    local ClearAllButton = Instance.new("TextButton")
    ClearAllButton.BackgroundColor3 = Library.Scheme.BackgroundColor
    ClearAllButton.BackgroundTransparency = 0.35
    ClearAllButton.BorderSizePixel = 0
    ClearAllButton.AutoButtonColor = false
    ClearAllButton.Text = ""
    ClearAllButton.AnchorPoint = Vector2.new(1, 0)
    ClearAllButton.Position = UDim2.new(1, 0, 0, -3)
    ClearAllButton.Size = UDim2.fromOffset(76, 26)
    ClearAllButton.Parent = PlaylistHeaderRow
    Library:AddToRegistry(ClearAllButton, { BackgroundColor3 = "BackgroundColor" })
    MakeCorner(Library, ClearAllButton, Library.CornerRadius, true)
    MakeStroke(Library, ClearAllButton)

    local ClearAllIcon = SafeIcon(Library, ClearAllButton, "trash-2", 13, "FontColor", "X")
    ClearAllIcon.AnchorPoint = Vector2.new(0, 0.5)
    ClearAllIcon.Position = UDim2.new(0, 10, 0.5, 0)

    local ClearAllLabel = MakeText(Library, ClearAllButton, "Clear All", 10, true, 0.1)
    ClearAllLabel.Position = UDim2.fromOffset(29, 0)
    ClearAllLabel.Size = UDim2.new(1, -34, 1, 0)

    ClearAllButton.MouseEnter:Connect(function()
        TweenService:Create(ClearAllButton, Library.TweenInfo, { BackgroundTransparency = 0.15 }):Play()
    end)
    ClearAllButton.MouseLeave:Connect(function()
        TweenService:Create(ClearAllButton, Library.TweenInfo, { BackgroundTransparency = 0.35 }):Play()
    end)
    ClearAllButton.MouseButton1Click:Connect(function()
        ClearPlaylist()
    end)

    --// Add row: type an asset id or a .mp3 file name from the workspace folder
    local AddRow = Instance.new("Frame")
    AddRow.BackgroundTransparency = 1
    AddRow.Size = UDim2.new(1, 0, 0, 34)
    AddRow.LayoutOrder = 2
    AddRow.Parent = PlaylistCard

    local AddLayout = Instance.new("UIListLayout")
    AddLayout.FillDirection = Enum.FillDirection.Horizontal
    AddLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    AddLayout.SortOrder = Enum.SortOrder.LayoutOrder
    AddLayout.Padding = UDim.new(0, 6)
    AddLayout.Parent = AddRow

    local InputBox = Instance.new("TextBox")
    InputBox.Name = "MusicInput"
    InputBox.BackgroundColor3 = Library.Scheme.BackgroundColor
    InputBox.BackgroundTransparency = 0.35
    InputBox.BorderSizePixel = 0
    InputBox.Size = UDim2.new(1, -160, 1, 0)
    InputBox.Text = ""
    InputBox.PlaceholderText = "Asset ID or file .mp3"
    InputBox.TextSize = 12
    InputBox.TextXAlignment = Enum.TextXAlignment.Left
    InputBox.ClearTextOnFocus = false
    InputBox.ClipsDescendants = true
    InputBox.Parent = AddRow
    Library:AddToRegistry(InputBox, { BackgroundColor3 = "BackgroundColor", TextColor3 = "FontColor", FontFace = "Font" })
    InputBox.TextColor3 = Library.Scheme.FontColor
    InputBox.PlaceholderColor3 = Library.Scheme.FontColor:Lerp(Library.Scheme.MainColor, 0.6)
    InputBox.FontFace = Library.Scheme.Font
    MakeCorner(Library, InputBox, Library.CornerRadius, true)
    MakeStroke(Library, InputBox)

    local InputPadding = Instance.new("UIPadding")
    InputPadding.PaddingLeft = UDim.new(0, 10)
    InputPadding.PaddingRight = UDim.new(0, 10)
    InputPadding.Parent = InputBox

    local function MakePillButton(Text: string, IconName: string, Fallback: string, Order: number, OnClick: any): TextButton
        local Button = Instance.new("TextButton")
        Button.BackgroundColor3 = Library.Scheme.BackgroundColor
        Button.BackgroundTransparency = 0.35
        Button.BorderSizePixel = 0
        Button.AutoButtonColor = false
        Button.Text = ""
        Button.Size = UDim2.fromOffset(0, 34)
        Button.LayoutOrder = Order
        Button.Parent = AddRow
        Library:AddToRegistry(Button, { BackgroundColor3 = "BackgroundColor" })
        MakeCorner(Library, Button, Library.CornerRadius, true)
        MakeStroke(Library, Button)

        local Icon = SafeIcon(Library, Button, IconName, 15, "AccentColor", Fallback)
        Icon.AnchorPoint = Vector2.new(0, 0.5)
        Icon.Position = UDim2.new(0, 10, 0.5, 0)

        local Label = MakeText(Library, Button, Text, 12, true, 0)
        Label.Position = UDim2.fromOffset(31, 0)
        Label.Size = UDim2.new(1, -37, 1, 0)

        local TextWidth = select(1, Library:GetTextBounds(Text, Library.Scheme.Font, 12))
        Button.Size = UDim2.fromOffset(math.ceil(TextWidth) + 42, 34)

        Button.MouseEnter:Connect(function()
            TweenService:Create(Button, Library.TweenInfo, { BackgroundTransparency = 0.15 }):Play()
        end)
        Button.MouseLeave:Connect(function()
            TweenService:Create(Button, Library.TweenInfo, { BackgroundTransparency = 0.35 }):Play()
        end)
        Button.MouseButton1Click:Connect(OnClick)
        return Button
    end

    MakePillButton("Add", "plus", "+", 2, function()
        if TryAddSource(InputBox.Text) then
            InputBox.Text = ""
        end
    end)

    --// Workspace file picker: lists audio files found in the executor workspace folder
    local FilesPanel = Instance.new("Frame")
    FilesPanel.Name = "WorkspaceFiles"
    FilesPanel.BackgroundColor3 = Library.Scheme.BackgroundColor
    FilesPanel.BackgroundTransparency = 0.55
    FilesPanel.BorderSizePixel = 0
    FilesPanel.Size = UDim2.new(1, 0, 0, 0)
    FilesPanel.AutomaticSize = Enum.AutomaticSize.Y
    FilesPanel.ClipsDescendants = true
    FilesPanel.LayoutOrder = 3
    FilesPanel.Visible = false
    FilesPanel.Parent = PlaylistCard
    Library:AddToRegistry(FilesPanel, { BackgroundColor3 = "BackgroundColor" })
    MakeCorner(Library, FilesPanel, 4)

    local FilesLayout = Instance.new("UIListLayout")
    FilesLayout.SortOrder = Enum.SortOrder.LayoutOrder
    FilesLayout.Padding = UDim.new(0, 6)
    FilesLayout.Parent = FilesPanel

    local FilesPadding = Instance.new("UIPadding")
    FilesPadding.PaddingTop = UDim.new(0, 8)
    FilesPadding.PaddingBottom = UDim.new(0, 8)
    FilesPadding.PaddingLeft = UDim.new(0, 8)
    FilesPadding.PaddingRight = UDim.new(0, 8)
    FilesPadding.Parent = FilesPanel

    local FilesTitle = MakeText(Library, FilesPanel, "AUDIO FILES IN WORKSPACE FOLDER", 9, true, 0.35)
    FilesTitle.Size = UDim2.new(1, 0, 0, 12)
    FilesTitle.LayoutOrder = 1

    local FilesScroll = Instance.new("ScrollingFrame")
    FilesScroll.BackgroundTransparency = 1
    FilesScroll.Size = UDim2.new(1, 0, 0, 128)
    FilesScroll.CanvasSize = UDim2.fromOffset(0, 0)
    FilesScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    FilesScroll.ScrollBarThickness = 2
    FilesScroll.ScrollingDirection = Enum.ScrollingDirection.Y
    FilesScroll.BorderSizePixel = 0
    FilesScroll.LayoutOrder = 2
    FilesScroll.Parent = FilesPanel
    Library:AddToRegistry(FilesScroll, { ScrollBarImageColor3 = "OutlineColor" })
    FilesScroll.ScrollBarImageColor3 = Library.Scheme.OutlineColor

    local FilesHolder = Instance.new("Frame")
    FilesHolder.BackgroundTransparency = 1
    FilesHolder.Size = UDim2.new(1, 0, 0, 0)
    FilesHolder.AutomaticSize = Enum.AutomaticSize.Y
    FilesHolder.Parent = FilesScroll

    local FilesHolderLayout = Instance.new("UIListLayout")
    FilesHolderLayout.SortOrder = Enum.SortOrder.LayoutOrder
    FilesHolderLayout.Padding = UDim.new(0, 4)
    FilesHolderLayout.Parent = FilesHolder

    local function RebuildFilesList(Files: { string })
        for _, Child in FilesHolder:GetChildren() do
            if Child:IsA("GuiObject") then
                Child:Destroy()
            end
        end

        if #Files == 0 then
            local EmptyFiles = MakeText(Library, FilesHolder, "No .mp3 / .ogg / .wav files found.", 10, false, 0.35)
            EmptyFiles.Size = UDim2.new(1, 0, 0, 22)
            EmptyFiles.TextXAlignment = Enum.TextXAlignment.Center
            EmptyFiles.LayoutOrder = 1
            return
        end

        for Order, Path in Files do
            local Row = Instance.new("TextButton")
            Row.BackgroundColor3 = Library.Scheme.BackgroundColor
            Row.BackgroundTransparency = 0.45
            Row.BorderSizePixel = 0
            Row.AutoButtonColor = false
            Row.Text = ""
            Row.Size = UDim2.new(1, 0, 0, 26)
            Row.LayoutOrder = Order
            Row.Parent = FilesHolder
            Library:AddToRegistry(Row, { BackgroundColor3 = "BackgroundColor" })
            MakeCorner(Library, Row, 4)

            local RowIcon = SafeIcon(Library, Row, "plus", 14, "AccentColor", "+")
            RowIcon.AnchorPoint = Vector2.new(1, 0.5)
            RowIcon.Position = UDim2.new(1, -10, 0.5, 0)

            local RowLabel = MakeText(Library, Row, tostring(Path:match("[^/]+$") or Path), 11, false, 0.1)
            RowLabel.Position = UDim2.fromOffset(10, 0)
            RowLabel.Size = UDim2.new(1, -36, 1, 0)

            Row.MouseEnter:Connect(function()
                TweenService:Create(Row, Library.TweenInfo, { BackgroundTransparency = 0.2 }):Play()
            end)
            Row.MouseLeave:Connect(function()
                TweenService:Create(Row, Library.TweenInfo, { BackgroundTransparency = 0.45 }):Play()
            end)
            Row.MouseButton1Click:Connect(function()
                TryAddSource(Path)
            end)
        end
    end

    local FilesOpen = false
    local function ToggleFiles()
        FilesOpen = not FilesOpen
        FilesPanel.Visible = FilesOpen

        if FilesOpen then
            local Files = ScanWorkspaceAudioFiles()
            RebuildFilesList(Files)

            if #Files == 0 then
                Notify("Music Player", "No .mp3 files were found in the executor workspace folder.", 4)
            end
        end
    end

    MakePillButton("Files", "folder-open", "+", 3, function()
        ToggleFiles()
    end)

    InputBox.FocusLost:Connect(function(EnterPressed)
        if EnterPressed and Trim(InputBox.Text) ~= "" then
            if TryAddSource(InputBox.Text) then
                InputBox.Text = ""
            end
        end
    end)

    --// Song list
    local SongList = Instance.new("ScrollingFrame")
    SongList.Name = "SongList"
    SongList.BackgroundTransparency = 1
    SongList.Size = UDim2.new(1, 0, 0, 168)
    SongList.CanvasSize = UDim2.fromOffset(0, 0)
    SongList.AutomaticCanvasSize = Enum.AutomaticSize.Y
    SongList.ScrollBarThickness = 2
    SongList.ScrollingDirection = Enum.ScrollingDirection.Y
    SongList.BorderSizePixel = 0
    SongList.LayoutOrder = 4
    SongList.Parent = PlaylistCard
    Library:AddToRegistry(SongList, { ScrollBarImageColor3 = "OutlineColor" })
    SongList.ScrollBarImageColor3 = Library.Scheme.OutlineColor

    local SongsHolder = Instance.new("Frame")
    SongsHolder.BackgroundTransparency = 1
    SongsHolder.Size = UDim2.new(1, 0, 0, 0)
    SongsHolder.AutomaticSize = Enum.AutomaticSize.Y
    SongsHolder.Parent = SongList

    local SongsLayout = Instance.new("UIListLayout")
    SongsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    SongsLayout.Padding = UDim.new(0, 6)
    SongsLayout.Parent = SongsHolder

    local EmptyLabel = MakeText(Library, SongsHolder, "Playlist is empty - add an asset ID or a .mp3 file", 11, false, 0.3)
    EmptyLabel.Size = UDim2.new(1, 0, 0, 44)
    EmptyLabel.TextXAlignment = Enum.TextXAlignment.Center
    EmptyLabel.LayoutOrder = 0

    --// Player logic

    UpdatePlayPauseIcon = function()
        local Playing = Sound.IsPlaying
        if PlayIcon then
            PlayIcon.Visible = not Playing
        end
        if PauseIcon then
            PauseIcon.Visible = Playing
        end
    end

    local LastStatus = ""
    UpdateStatus = function()
        local Status = "Stopped"
        if Sound.IsPlaying then
            Status = "Playing"
        elseif CurrentIndex and PausedManually then
            Status = "Paused"
        end

        if Status ~= LastStatus then
            LastStatus = Status
            SetText(StatusLabel, Status)
        end
    end

    UpdateSeek = function()
        local Length = Sound.TimeLength or 0
        local Position = Sound.TimePosition or 0

        if not DraggingSeek then
            SetSeekVisual(Length > 0 and math.clamp(Position / Length, 0, 1) or 0)
        end

        SetText(ElapsedLabel, FormatTime(Position))
        SetText(DurationLabel, FormatTime(Length))
    end

    RefreshPlaylist = function()
        for _, OldEntry in EntryFrames do
            if OldEntry then
                OldEntry:Destroy()
            end
        end
        table.clear(EntryFrames)

        SetText(CountLabel, tostring(#Playlist) .. (#Playlist == 1 and " song" or " songs"))
        EmptyLabel.Visible = #Playlist == 0

        for Index, Song in Playlist do
            local IsCurrent = Index == CurrentIndex

            local Entry = Instance.new("TextButton")
            Entry.Name = "Song_" .. tostring(Index)
            Entry.BackgroundColor3 = IsCurrent and Library.Scheme.AccentColor or Library.Scheme.BackgroundColor
            Entry.BackgroundTransparency = IsCurrent and 0.82 or 0.35
            Entry.BorderSizePixel = 0
            Entry.AutoButtonColor = false
            Entry.Text = ""
            Entry.Size = UDim2.new(1, -4, 0, 40)
            Entry.LayoutOrder = Index
            Entry.Parent = SongsHolder
            Library:AddToRegistry(Entry, {
                BackgroundColor3 = IsCurrent and "AccentColor" or "BackgroundColor",
            })
            MakeCorner(Library, Entry, 4)
            MakeStroke(Library, Entry)

            if IsCurrent then
                local NowIcon = SafeIcon(Library, Entry, "music", 13, "AccentColor", "M")
                NowIcon.AnchorPoint = Vector2.new(0, 0.5)
                NowIcon.Position = UDim2.new(0, 10, 0.5, 0)
            else
                local NumberLabel = MakeText(Library, Entry, tostring(Index), 10, true, 0.4)
                NumberLabel.AnchorPoint = Vector2.new(0, 0.5)
                NumberLabel.Position = UDim2.new(0, 10, 0.5, 0)
                NumberLabel.Size = UDim2.fromOffset(20, 14)
                NumberLabel.TextXAlignment = Enum.TextXAlignment.Center
            end

            local EntryTitle = MakeText(Library, Entry, tostring(Song.Title), 12, IsCurrent, IsCurrent and 0 or 0.05)
            EntryTitle.Position = UDim2.fromOffset(36, 6)
            EntryTitle.Size = UDim2.new(1, -80, 0, 16)

            if IsCurrent then
                Library:AddToRegistry(EntryTitle, { TextColor3 = "AccentColor", FontFace = "Font" })
                EntryTitle.TextColor3 = Library.Scheme.AccentColor
            end

            local EntrySub = MakeText(
                Library,
                Entry,
                (IsCurrent and "Now Playing - " or "") .. tostring(Song.SourceLabel),
                9,
                false,
                0.4
            )
            EntrySub.Position = UDim2.fromOffset(36, 23)
            EntrySub.Size = UDim2.new(1, -80, 0, 12)

            local RemoveButton = Instance.new("TextButton")
            RemoveButton.BackgroundTransparency = 1
            RemoveButton.BorderSizePixel = 0
            RemoveButton.AutoButtonColor = false
            RemoveButton.Text = ""
            RemoveButton.AnchorPoint = Vector2.new(1, 0.5)
            RemoveButton.Position = UDim2.new(1, -6, 0.5, 0)
            RemoveButton.Size = UDim2.fromOffset(28, 28)
            RemoveButton.Parent = Entry

            local RemoveIcon = SafeIcon(Library, RemoveButton, "x", 15, "FontColor", "X")
            RemoveIcon.AnchorPoint = Vector2.new(0.5, 0.5)
            RemoveIcon.Position = UDim2.fromScale(0.5, 0.5)

            RemoveButton.MouseEnter:Connect(function()
                SetIconColorScheme(Library, RemoveIcon, "AccentColor")
            end)
            RemoveButton.MouseLeave:Connect(function()
                SetIconColorScheme(Library, RemoveIcon, "FontColor")
            end)
            RemoveButton.MouseButton1Click:Connect(function()
                RemoveAt(Index)
            end)

            Entry.MouseButton1Click:Connect(function()
                if Index == CurrentIndex then
                    TogglePlayPause()
                else
                    PlayIndex(Index)
                end
            end)

            table.insert(EntryFrames, Entry)
        end
    end

    StopPlayback = function(ResetSelection: boolean?)
        Sound:Stop()
        PausedManually = false

        if ResetSelection then
            CurrentIndex = nil
            SetText(SongTitle, "Nothing playing")
            SetText(SongSub, "Add a song from the playlist below")
            RefreshPlaylist()
        end

        UpdatePlayPauseIcon()
    end

    PlayIndex = function(Index: number)
        local Song = Playlist[Index]
        if not Song then
            return
        end

        CurrentIndex = Index
        PausedManually = false

        Sound:Stop()
        Sound.SoundId = Song.SoundId
        Sound.TimePosition = 0

        task.defer(function()
            if Sound.Parent then
                Sound:Play()
            end
        end)

        SetText(SongTitle, tostring(Song.Title))
        SetText(SongSub, tostring(Song.SourceLabel))
        RefreshPlaylist()
        UpdatePlayPauseIcon()
    end

    Advance = function(Direction: number, Auto: boolean?)
        local Count = #Playlist
        if Count == 0 then
            StopPlayback(true)
            return
        end

        local Target
        if Shuffling and Count > 1 then
            repeat
                Target = math.random(Count)
            until Target ~= CurrentIndex
        else
            Target = (CurrentIndex or 0) + Direction

            if Target > Count then
                if Auto and not Looping then
                    StopPlayback(false)
                    return
                end
                Target = 1
            elseif Target < 1 then
                Target = Count
            end
        end

        PlayIndex(Target)
    end

    Previous = function()
        --// Restart the current song when it already played for a few seconds
        if CurrentIndex and (Sound.TimePosition or 0) > 3 then
            Sound:Stop()
            Sound.TimePosition = 0
            PausedManually = false
            task.defer(function()
                if Sound.Parent then
                    Sound:Play()
                end
            end)
            UpdatePlayPauseIcon()
            return
        end

        Advance(-1, false)
    end

    TogglePlayPause = function()
        if not CurrentIndex then
            if #Playlist > 0 then
                local Start = 1
                if Shuffling and #Playlist > 1 then
                    Start = math.random(1, #Playlist)
                end
                PlayIndex(Start)
            else
                Notify("Music Player", "The playlist is empty. Add an asset ID or a .mp3 file first.", 4)
            end
            return
        end

        if Sound.IsPlaying then
            Sound:Pause()
            PausedManually = true
        elseif PausedManually and (Sound.TimePosition or 0) > 0 then
            Sound:Resume()
            PausedManually = false
        else
            local Length = Sound.TimeLength or 0
            local Position = Sound.TimePosition or 0

            --// Finished naturally: restart from the beginning instead of the end position
            if Length > 0 and Position >= Length - 0.05 then
                Sound:Stop()
            end

            PausedManually = false
            task.defer(function()
                if Sound.Parent then
                    Sound:Play()
                end
            end)
        end

        UpdatePlayPauseIcon()
    end

    TryAddSource = function(Raw: any): boolean
        local Parsed = ParseMusicSource(Raw)
        if not Parsed then
            Notify("Music Player", "Enter a valid Roblox asset ID or a .mp3 file name.", 4)
            return false
        end

        if Parsed.Type == "Asset" then
            local Key = "asset:" .. Parsed.Id
            for _, Song in Playlist do
                if Song.Key == Key then
                    Notify("Music Player", "That song is already in the playlist.", 3)
                    return false
                end
            end

            local Song = {
                Key = Key,
                Title = "Audio " .. Parsed.Id,
                SoundId = Parsed.SoundId,
                SourceLabel = "Asset ID - " .. Parsed.Id,
            }
            table.insert(Playlist, Song)
            RefreshPlaylist()
            Notify("Music Player", "Added asset " .. Parsed.Id .. " to the playlist.", 3)

            --// Fetch the real asset name in the background
            task.spawn(function()
                local Ok, Info = pcall(function()
                    return MarketplaceService:GetProductInfo(Parsed.Id)
                end)
                if Ok and typeof(Info) == "table" and Info.Name and Info.Name ~= "" then
                    Song.Title = tostring(Info.Name)
                    RefreshPlaylist()

                    if CurrentIndex and Playlist[CurrentIndex] == Song then
                        SetText(SongTitle, Song.Title)
                    end
                end
            end)

            return true
        end

        --// Local .mp3 file from the executor workspace folder
        local FileName = Parsed.FileName
        local Key = "file:" .. FileName:lower()
        for _, Song in Playlist do
            if Song.Key == Key then
                Notify("Music Player", "That song is already in the playlist.", 3)
                return false
            end
        end

        if typeof(isfile) == "function" and not isfile(FileName) then
            Notify("Music Player", '"' .. FileName .. '" was not found in the executor workspace folder.', 5)
            return false
        end

        local Url
        local LoadOk = false
        if typeof(getsynasset) == "function" then
            LoadOk, Url = pcall(getsynasset, FileName)
        elseif typeof(getcustomasset) == "function" then
            LoadOk, Url = pcall(getcustomasset, FileName)
        end

        if not LoadOk or typeof(Url) ~= "string" or Url == "" then
            Notify(
                "Music Player",
                "This executor cannot load local audio files (getsynasset / getcustomasset not found).",
                5
            )
            return false
        end

        table.insert(Playlist, {
            Key = Key,
            Title = tostring(FileName:match("[^/]+$") or FileName),
            SoundId = Url,
            SourceLabel = "File - " .. FileName,
        })
        RefreshPlaylist()
        Notify("Music Player", 'Added "' .. FileName .. '" to the playlist.', 3)
        return true
    end

    RemoveAt = function(Index: number)
        if not Playlist[Index] then
            return
        end

        local WasCurrent = Index == CurrentIndex
        table.remove(Playlist, Index)

        if WasCurrent then
            StopPlayback(true)
        else
            if CurrentIndex and Index < CurrentIndex then
                CurrentIndex -= 1
            end
            RefreshPlaylist()
        end
    end

    ClearPlaylist = function()
        if #Playlist == 0 then
            return
        end

        table.clear(Playlist)
        StopPlayback(true)
        Notify("Music Player", "Playlist cleared.", 3)
    end

    SetToggleVisual = function(Info: any, Active: boolean)
        local Button = Info.Root

        if Active then
            Button.BackgroundColor3 = Library.Scheme.AccentColor
            Button.BackgroundTransparency = 0.15
            Info.Resting = 0.15
            if Library.Registry and Library.Registry[Button] then
                Library.Registry[Button].BackgroundColor3 = "AccentColor"
            end
            if Info.Icon then
                SetIconColorScheme(Library, Info.Icon, "WhiteColor")
            end
        else
            Button.BackgroundColor3 = Library.Scheme.BackgroundColor
            Button.BackgroundTransparency = 0.35
            Info.Resting = 0.35
            if Library.Registry and Library.Registry[Button] then
                Library.Registry[Button].BackgroundColor3 = "BackgroundColor"
            end
            if Info.Icon then
                SetIconColorScheme(Library, Info.Icon, "FontColor")
            end
        end
    end

    SyncAll = function()
        UpdateSeek()
        UpdateStatus()
        UpdatePlayPauseIcon()
    end

    --// Auto advance when a song ends (loop / shuffle aware)
    table.insert(Connections, Sound.Ended:Connect(function()
        if GuardAdvance then
            return
        end
        GuardAdvance = true
        Advance(1, true)
        GuardAdvance = false
    end))

    table.insert(Connections, RunService.RenderStepped:Connect(function()
        if not Page.Parent or not Page.Visible then
            return
        end

        UpdateSeek()
        UpdateStatus()
        UpdatePlayPauseIcon()
    end))

    RefreshPlaylist()
    SyncAll()

    local API = {
        Page = Page,
        Sound = Sound,
        Play = TogglePlayPause,
        Pause = function()
            if Sound.IsPlaying then
                Sound:Pause()
                PausedManually = true
            end
            UpdatePlayPauseIcon()
        end,
        Stop = function()
            StopPlayback(false)
        end,
        Next = function()
            Advance(1, false)
        end,
        Previous = Previous,
        Add = TryAddSource,
        RemoveAt = RemoveAt,
        Clear = ClearPlaylist,
        SetVolume = function(Value: number)
            VolumeSlider.SetValue(tonumber(Value) or 50)
        end,
        SetSpeed = function(Value: number)
            SpeedSlider.SetValue(tonumber(Value) or 1)
        end,
        SetLoop = function(Enabled: boolean)
            Looping = Enabled == true
            SetToggleVisual(LoopButton, Looping)
        end,
        SetShuffle = function(Enabled: boolean)
            Shuffling = Enabled == true
            SetToggleVisual(ShuffleButton, Shuffling)
        end,
        GetPlaylist = function()
            return Playlist
        end,
        Sync = SyncAll,
        Destroy = function()
            for _, Connection in Connections do
                if Connection and Connection.Connected then
                    Connection:Disconnect()
                end
            end
            table.clear(Connections)

            if Sound and Sound.Parent then
                Sound:Destroy()
            end
        end,
    }

    return Page, API
end

--// Dashboard creation \\--
function DashboardManager:CreateDashboard(Tab: any, Config: any)
    local Library = DashboardManager.Library
    assert(Library, "Library is not set, call DashboardManager:SetLibrary(Library) first.")
    assert(typeof(Tab) == "table" and Tab.Container, "Expected a valid Tab for the dashboard.")

    Config = Library:Validate(Config or {}, Defaults)

    local Window = Tab.Window
    local DiscordInviteCode = ExtractDiscordInviteCode(Config.DiscordInvite)

    --// Take over the tab: the sides are hidden so the dashboard owns the whole page \\--
    local OriginalSidesVisible = {}
    if typeof(Tab.Sides) == "table" then
        for _, Side in Tab.Sides do
            OriginalSidesVisible[Side] = Side.Visible
            Side.Visible = false
        end
    end

    --// Environment info \\--
    local ExecutorName = "Roblox Studio"
    local PlaceName = "Unknown Place"
    local Region = "Unknown"

    pcall(function()
        if identifyexecutor then
            ExecutorName = tostring(select(1, identifyexecutor()))
        end
    end)
    pcall(function()
        PlaceName = MarketplaceService:GetProductInfo(game.PlaceId).Name
    end)
    task.spawn(function()
        pcall(function()
            Region = LocalizationService:GetCountryRegionForPlayerAsync(LocalPlayer)
        end)
    end)

    --// Root \\--
    local Root = Instance.new("ScrollingFrame")
    Root.Name = "Dashboard"
    Root.BackgroundTransparency = 1
    Root.Size = UDim2.fromScale(1, 1)
    Root.CanvasSize = UDim2.fromOffset(0, 0)
    Root.AutomaticCanvasSize = Enum.AutomaticSize.Y
    Root.ScrollBarThickness = 2
    Root.ScrollingDirection = Enum.ScrollingDirection.Y
    Root.BorderSizePixel = 0
    Root.Parent = Tab.Container

    Library:AddToRegistry(Root, { ScrollBarImageColor3 = "OutlineColor" })
    Root.ScrollBarImageColor3 = Library.Scheme.OutlineColor

    local RootLayout = Instance.new("UIListLayout")
    RootLayout.SortOrder = Enum.SortOrder.LayoutOrder
    RootLayout.Padding = UDim.new(0, 8)
    RootLayout.Parent = Root

    local RootPadding = Instance.new("UIPadding")
    RootPadding.PaddingTop = UDim.new(0, 6)
    RootPadding.PaddingBottom = UDim.new(0, 6)
    RootPadding.PaddingLeft = UDim.new(0, 6)
    RootPadding.PaddingRight = UDim.new(0, 6)
    RootPadding.Parent = Root

    --// Profile card \\--
    local Profile = MakePanel(Library, Root, UDim2.new(1, 0, 0, 74))
    Profile.LayoutOrder = 1

    local AvatarBox = Instance.new("Frame")
    AvatarBox.BackgroundColor3 = Library.Scheme.BackgroundColor
    AvatarBox.BackgroundTransparency = 0.2
    AvatarBox.BorderSizePixel = 0
    AvatarBox.Size = UDim2.fromOffset(58, 58)
    AvatarBox.Position = UDim2.fromOffset(10, 8)
    AvatarBox.Parent = Profile

    Library:AddToRegistry(AvatarBox, { BackgroundColor3 = "BackgroundColor" })
    MakeCorner(Library, AvatarBox, 6)
    MakeStroke(Library, AvatarBox)

    local Avatar = Instance.new("ImageLabel")
    Avatar.BackgroundTransparency = 1
    Avatar.BorderSizePixel = 0
    Avatar.Size = UDim2.fromScale(1, 1)
    Avatar.Parent = AvatarBox
    MakeCorner(Library, Avatar, 6)

    task.spawn(function()
        local Success, Content = pcall(function()
            return Players:GetUserThumbnailAsync(
                LocalPlayer.UserId,
                Enum.ThumbnailType.HeadShot,
                Enum.ThumbnailSize.Size420x420
            )
        end)

        if Success and typeof(Content) == "string" and Root.Parent then
            Avatar.Image = Content
        end
    end)

    local Welcome = MakeText(Library, Profile, "Hello, " .. tostring(LocalPlayer.DisplayName), 18, true, 0)
    Welcome.Position = UDim2.fromOffset(82, 16)
    Welcome.Size = UDim2.new(1, -98, 0, 24)

    local Username = MakeText(
        Library,
        Profile,
        GetGreeting(Config.Greetings) .. " | @" .. tostring(LocalPlayer.Name),
        12,
        false,
        0.35
    )
    Username.Position = UDim2.fromOffset(82, 42)
    Username.Size = UDim2.new(1, -98, 0, 18)

    --// Segments bar \\--
    local Segments = MakePanel(Library, Root, UDim2.new(1, 0, 0, 48))
    Segments.LayoutOrder = 2

    local SegmentLayout = Instance.new("UIListLayout")
    SegmentLayout.FillDirection = Enum.FillDirection.Horizontal
    SegmentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    SegmentLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    SegmentLayout.SortOrder = Enum.SortOrder.LayoutOrder
    SegmentLayout.Padding = UDim.new(0, 8)
    SegmentLayout.Parent = Segments

    local SegmentPadding = Instance.new("UIPadding")
    SegmentPadding.PaddingTop = UDim.new(0, 7)
    SegmentPadding.PaddingBottom = UDim.new(0, 7)
    SegmentPadding.PaddingLeft = UDim.new(0, 7)
    SegmentPadding.PaddingRight = UDim.new(0, 7)
    SegmentPadding.Parent = Segments

    local Pages = {}
    local SegmentButtons = {}
    local SegmentCount = 0
    local ActivePage = "Details"

    --// Forward declared so SelectPage can reach them before they exist
    local ContentHolder
    local MusicAPI

    local function SelectPage(PageName: string)
        ActivePage = PageName

        for Name, Page in Pages do
            Page.Visible = Name == PageName
        end

        --// Only the Details page lives inside ContentHolder; the music page owns its own height
        if ContentHolder then
            ContentHolder.Visible = PageName == "Details"
        end

        if PageName == "Music" and MusicAPI then
            MusicAPI.Sync()
        end

        for Name, Button in SegmentButtons do
            local IsActive = Name == PageName

            Button.Root.BackgroundTransparency = IsActive and 0.05 or 0.55
            SetIconColorScheme(Library, Button.Icon, IsActive and "AccentColor" or "FontColor")
            Button.Label.TextTransparency = IsActive and 0 or 0.25
        end
    end

    local VisibleSegmentCount = 0
    local SegmentConfig = typeof(Config.Segments) == "table" and Config.Segments or {}

    local ShowDetailsSegment = Config.ShowDetailsSegment ~= false
    local ShowMusicSegment = Config.ShowMusicSegment ~= false
    VisibleSegmentCount = (ShowDetailsSegment and 1 or 0) + (ShowMusicSegment and 1 or 0)

    if VisibleSegmentCount <= 0 then
        ShowDetailsSegment = true
        VisibleSegmentCount = 1
    end

    --// Pages + segment buttons \\--
    local CardGap = 10
    local ContentHeight = 154 + CardGap + 112 --// tallest column: server + discord cards

    --// Holds the Details page only; hidden while the taller Music page is open
    ContentHolder = Instance.new("Frame")
    ContentHolder.BackgroundTransparency = 1
    ContentHolder.Size = UDim2.new(1, 0, 0, ContentHeight)
    ContentHolder.LayoutOrder = 3
    ContentHolder.Parent = Root

    local function CreateContentPage(): Frame
        local Page = Instance.new("Frame")
        Page.BackgroundTransparency = 1
        Page.BorderSizePixel = 0
        Page.Size = UDim2.fromScale(1, 1)
        Page.ClipsDescendants = true
        Page.Visible = false
        Page.Parent = ContentHolder
        return Page
    end

    local function MakeSegment(Name: string, Text: string, IconName: string)
        local WidthScale = 1 / math.max(VisibleSegmentCount, 1)

        local Button = Instance.new("TextButton")
        Button.BackgroundColor3 = Library.Scheme.BackgroundColor
        Button.BackgroundTransparency = 0.55
        Button.BorderSizePixel = 0
        Button.AutoButtonColor = false
        Button.Text = ""
        Button.Size = UDim2.new(WidthScale, -6, 0, 34)
        SegmentCount += 1
        Button.LayoutOrder = SegmentCount
        Button.ClipsDescendants = true
        Button.Parent = Segments

        Library:AddToRegistry(Button, { BackgroundColor3 = "BackgroundColor" })
        MakeCorner(Library, Button, Library.CornerRadius, true)
        MakeStroke(Library, Button)

        local Inner = Instance.new("Frame")
        Inner.AnchorPoint = Vector2.new(0.5, 0.5)
        Inner.BackgroundTransparency = 1
        Inner.BorderSizePixel = 0
        Inner.Position = UDim2.fromScale(0.5, 0.5)
        Inner.Size = UDim2.new(1, -14, 1, 0)
        Inner.Parent = Button

        local InnerLayout = Instance.new("UIListLayout")
        InnerLayout.FillDirection = Enum.FillDirection.Horizontal
        InnerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        InnerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
        InnerLayout.SortOrder = Enum.SortOrder.LayoutOrder
        InnerLayout.Padding = UDim.new(0, 7)
        InnerLayout.Parent = Inner

        local IconImage = MakeIcon(Library, Button, IconName, 17, "FontColor")
        IconImage.Parent = Inner
        IconImage.LayoutOrder = 1

        local Label = MakeText(Library, Button, Text, 13, true, 0.25)
        Label.Parent = Inner
        Label.LayoutOrder = 2

        local TextWidth = select(1, Library:GetTextBounds(Text, Library.Scheme.Font, 13))
        Label.Size = UDim2.new(0, math.max(24, TextWidth + 2), 0, 18)
        Label.TextXAlignment = Enum.TextXAlignment.Left

        Button.MouseEnter:Connect(function()
            if ActivePage ~= Name then
                TweenService:Create(Button, Library.TweenInfo, { BackgroundTransparency = 0.35 }):Play()
            end
        end)
        Button.MouseLeave:Connect(function()
            if ActivePage ~= Name then
                TweenService:Create(Button, Library.TweenInfo, { BackgroundTransparency = 0.55 }):Play()
            end
        end)
        Button.MouseButton1Click:Connect(function()
            SelectPage(Name)
        end)

        SegmentButtons[Name] = { Root = Button, Icon = IconImage, Label = Label }
    end

    local DetailsPage = CreateContentPage()
    Pages.Details = DetailsPage

    --// Details page \\--
    local LeftColumn = Instance.new("Frame")
    LeftColumn.BackgroundTransparency = 1
    LeftColumn.BorderSizePixel = 0
    LeftColumn.Size = UDim2.new(0.52, -4, 1, 0)
    LeftColumn.Parent = DetailsPage

    local LeftColumnLayout = Instance.new("UIListLayout")
    LeftColumnLayout.SortOrder = Enum.SortOrder.LayoutOrder
    LeftColumnLayout.Padding = UDim.new(0, CardGap)
    LeftColumnLayout.Parent = LeftColumn

    local RightColumn = Instance.new("Frame")
    RightColumn.BackgroundTransparency = 1
    RightColumn.BorderSizePixel = 0
    RightColumn.Position = UDim2.new(0.52, 4, 0, 0)
    RightColumn.Size = UDim2.new(0.48, -4, 1, 0)
    RightColumn.Parent = DetailsPage

    local RightColumnLayout = Instance.new("UIListLayout")
    RightColumnLayout.SortOrder = Enum.SortOrder.LayoutOrder
    RightColumnLayout.Padding = UDim.new(0, CardGap)
    RightColumnLayout.Parent = RightColumn

    local StatLabels = {}
    local FriendLabels = {}
    local DiscordLabels = {}

    do
        --// Server card \\--
        local ServerCard = MakePanel(Library, LeftColumn, UDim2.new(1, 0, 0, 154))
        ServerCard.LayoutOrder = 1

        local ServerTitle = MakeText(Library, ServerCard, "Server", 15, true, 0)
        ServerTitle.Position = UDim2.fromOffset(14, 12)
        ServerTitle.Size = UDim2.new(1, -28, 0, 18)

        local ServerSub = MakeText(Library, ServerCard, tostring(PlaceName), 10, false, 0.45)
        ServerSub.Position = UDim2.fromOffset(14, 32)
        ServerSub.Size = UDim2.new(1, -28, 0, 14)

        StatLabels.Players = MakeStat(Library, ServerCard, "Players", "0 playing", 0, 58, 0.5)
        StatLabels.Capacity =
            MakeStat(Library, ServerCard, "Maximum Players", tostring(Players.MaxPlayers) .. " can join", 0.5, 58, 0.5)
        StatLabels.Latency = MakeStat(Library, ServerCard, "Latency", "...", 0, 104, 0.25)
        StatLabels.FPS = MakeStat(Library, ServerCard, "FPS", "...", 0.25, 104, 0.25)
        StatLabels.Region = MakeStat(Library, ServerCard, "Server Region", "...", 0.5, 104, 0.25)
        StatLabels.Runtime = MakeStat(Library, ServerCard, "In server for", "0s", 0.75, 104, 0.25)
    end

    do
        --// Discord card \\--
        local DiscordCard = Instance.new("TextButton")
        DiscordCard.BackgroundColor3 = Library.Scheme.AccentColor
        DiscordCard.BackgroundTransparency = 0.15
        DiscordCard.BorderSizePixel = 0
        DiscordCard.AutoButtonColor = false
        DiscordCard.Text = ""
        DiscordCard.Size = UDim2.new(1, 0, 0, 112)
        DiscordCard.LayoutOrder = 2
        DiscordCard.ClipsDescendants = true
        DiscordCard.Parent = LeftColumn

        Library:AddToRegistry(DiscordCard, { BackgroundColor3 = "AccentColor" })
        MakeCorner(Library, DiscordCard, Library.CornerRadius, true)
        MakeStroke(Library, DiscordCard)

        local DiscordIconBox = Instance.new("Frame")
        DiscordIconBox.BackgroundColor3 = Color3.new(1, 1, 1)
        DiscordIconBox.BackgroundTransparency = 0.9
        DiscordIconBox.BorderSizePixel = 0
        DiscordIconBox.Position = UDim2.fromOffset(14, 12)
        DiscordIconBox.Size = UDim2.fromOffset(32, 32)
        DiscordIconBox.Parent = DiscordCard
        MakeCorner(Library, DiscordIconBox, 6)

        local DiscordIcon = MakeIcon(Library, DiscordIconBox, "message-circle", 20, "WhiteColor")
        DiscordIcon.AnchorPoint = Vector2.new(0.5, 0.5)
        DiscordIcon.Position = UDim2.fromScale(0.5, 0.5)

        local DiscordTitle = MakeText(Library, DiscordCard, "Discord", 16, true, 0)
        DiscordTitle.Position = UDim2.fromOffset(56, 12)
        DiscordTitle.Size = UDim2.new(1, -72, 0, 20)
        Library:AddToRegistry(DiscordTitle, { TextColor3 = "WhiteColor", FontFace = "Font" })
        DiscordTitle.TextColor3 = Library.Scheme.WhiteColor

        local DiscordSubText = DiscordInviteCode ~= "" and "Tap to copy Discord invite"
            or "No Discord invite configured"

        local DiscordSub = MakeText(Library, DiscordCard, DiscordSubText, 10, false, 0.3)
        DiscordSub.Position = UDim2.fromOffset(56, 32)
        DiscordSub.Size = UDim2.new(1, -72, 0, 14)
        Library:AddToRegistry(DiscordSub, { TextColor3 = "WhiteColor", FontFace = "Font" })
        DiscordSub.TextColor3 = Library.Scheme.WhiteColor

        DiscordLabels.Online = MakeStat(Library, DiscordCard, "Member Online", "...", 0, 58, 0.5)
        DiscordLabels.Total = MakeStat(Library, DiscordCard, "All Member", "...", 0.5, 58, 0.5)

        DiscordCard.MouseEnter:Connect(function()
            TweenService:Create(DiscordCard, Library.TweenInfo, { BackgroundTransparency = 0.05 }):Play()
        end)
        DiscordCard.MouseLeave:Connect(function()
            TweenService:Create(DiscordCard, Library.TweenInfo, { BackgroundTransparency = 0.15 }):Play()
        end)

        DiscordCard.MouseButton1Click:Connect(function()
            if DiscordInviteCode == "" then
                if Library.Notify then
                    Library:Notify({
                        Title = "Discord",
                        Description = "No Discord invite is configured.",
                        Time = 3,
                    })
                end
                return
            end

            local Link = "https://discord.gg/" .. DiscordInviteCode

            if setclipboard then
                setclipboard(Link)
            elseif toclipboard then
                toclipboard(Link)
            elseif set_clipboard then
                set_clipboard(Link)
            end

            if Library.Notify then
                Library:Notify({
                    Title = "Copied",
                    Description = Link,
                    Time = 3,
                })
            end
        end)

        --// Discord member counts are fetched async so the window never freezes \\--
        if DiscordInviteCode ~= "" then
            task.spawn(function()
                local Success, Result = pcall(function()
                    return game:HttpGet(
                        ("https://discord.com/api/v10/invites/%s?with_counts=true"):format(DiscordInviteCode)
                    )
                end)

                if not Success then
                    DiscordLabels.Online.Text = "N/A"
                    DiscordLabels.Total.Text = "N/A"
                    return
                end

                local DecodeSuccess, Data = pcall(HttpService.JSONDecode, HttpService, Result)
                if not DecodeSuccess or typeof(Data) ~= "table" then
                    DiscordLabels.Online.Text = "N/A"
                    DiscordLabels.Total.Text = "N/A"
                    return
                end

                local OnlineCount = Data.approximate_presence_count
                local TotalCount = Data.approximate_member_count

                if DiscordLabels.Online.Parent then
                    DiscordLabels.Online.Text = OnlineCount and (tostring(OnlineCount) .. " online") or "N/A"
                    DiscordLabels.Total.Text = TotalCount and (tostring(TotalCount) .. " members") or "N/A"

                    if Data.guild and Data.guild.name and DiscordTitle.Parent then
                        DiscordTitle.Text = tostring(Data.guild.name)
                    end
                end
            end)
        end
    end

    do
        --// Executor card \\--
        local ExecutorStatus = "Executor support is unknown."
        local ExecutorColor = Library.Scheme.AccentColor
        local ExecutorSchemeIndex = "AccentColor"

        if table.find(Config.SupportedExecutors, ExecutorName) then
            ExecutorStatus = "Your executor seems to support this script."
            ExecutorColor = Color3.fromRGB(45, 180, 115)
            ExecutorSchemeIndex = nil
        elseif table.find(Config.UnsupportedExecutors, ExecutorName) then
            ExecutorStatus = "Your executor may not support this script."
            ExecutorColor = Color3.fromRGB(220, 70, 70)
            ExecutorSchemeIndex = nil
        end

        local ExecutorCard = MakePanel(Library, RightColumn, UDim2.new(1, 0, 0, 104))
        ExecutorCard.LayoutOrder = 1
        ExecutorCard.BackgroundColor3 = ExecutorColor
        ExecutorCard.BackgroundTransparency = 0.15

        if ExecutorSchemeIndex then
            Library:AddToRegistry(ExecutorCard, { BackgroundColor3 = ExecutorSchemeIndex })
        else
            Library:AddToRegistry(ExecutorCard, {})
        end

        local ExecutorTitle = MakeText(Library, ExecutorCard, ExecutorName, 17, true, 0)
        ExecutorTitle.Position = UDim2.fromOffset(18, 24)
        ExecutorTitle.Size = UDim2.new(1, -36, 0, 22)

        local ExecutorSub = MakeText(Library, ExecutorCard, ExecutorStatus, 12, false, 0.15)
        ExecutorSub.Position = UDim2.fromOffset(18, 49)
        ExecutorSub.Size = UDim2.new(1, -36, 0, 34)
        ExecutorSub.TextWrapped = true
        ExecutorSub.TextTruncate = Enum.TextTruncate.None
        ExecutorSub.TextYAlignment = Enum.TextYAlignment.Top
    end

    do
        --// Friends card \\--
        local FriendsCard = MakePanel(Library, RightColumn, UDim2.new(1, 0, 0, 154))
        FriendsCard.LayoutOrder = 2

        local FriendsTitle = MakeText(Library, FriendsCard, "Friends", 16, true, 0)
        FriendsTitle.Position = UDim2.fromOffset(14, 12)
        FriendsTitle.Size = UDim2.new(1, -28, 0, 20)

        local FriendsSub =
            MakeText(Library, FriendsCard, "Find out what your friends are currently doing", 10, false, 0.45)
        FriendsSub.Position = UDim2.fromOffset(14, 32)
        FriendsSub.Size = UDim2.new(1, -28, 0, 14)

        FriendLabels.InServer = MakeStat(Library, FriendsCard, "In Server", "...", 0, 58, 0.5)
        FriendLabels.Offline = MakeStat(Library, FriendsCard, "Offline", "...", 0.5, 58, 0.5)
        FriendLabels.Online = MakeStat(Library, FriendsCard, "Online", "...", 0, 104, 0.5)
        FriendLabels.All = MakeStat(Library, FriendsCard, "All", "...", 0.5, 104, 0.5)
    end

    --// Segment pages: the Details cards plus the built-in music player
    if ShowDetailsSegment then
        local DetailsSegment = SegmentConfig.Details or SegmentConfig[1] or {}
        MakeSegment(
            "Details",
            DetailsSegment.Text or DetailsSegment.Name or Config.DetailsText,
            DetailsSegment.Icon or Config.DetailsIcon
        )
    end

    if ShowMusicSegment then
        local MusicPage, MusicInstance = CreateMusicPlayerPage(Library, Root, {
            DefaultVolume = Config.DefaultVolume,
            DefaultSpeed = Config.DefaultSpeed,
            Notify = function(Data)
                if Library.Notify then
                    Library:Notify(Data)
                end
            end,
        })

        MusicAPI = MusicInstance
        Pages.Music = MusicPage
        MakeSegment("Music", Config.MusicText or "Music", Config.MusicIcon or "music")
    end

    SelectPage("Details")

    --// Live stats \\--
    local StartedAt = os.clock()
    local FrameTimes = {}
    local Accumulator = 0

    local FriendCache = {
        All = "...",
        Online = "...",
        Offline = "...",
        InServer = "...",
        Cooldown = 0,
    }

    local function UpdateFriends()
        if FriendCache.Cooldown > 0 then
            FriendCache.Cooldown -= 1
            return
        end

        FriendCache.Cooldown = 30

        task.spawn(function()
            local OnlineFriends = 0
            local TotalFriends = 0
            local InServer = 0

            pcall(function()
                OnlineFriends = #LocalPlayer:GetFriendsOnline()
            end)

            pcall(function()
                local FriendPages = Players:GetFriendsAsync(LocalPlayer.UserId)
                while true do
                    for _, Data in FriendPages:GetCurrentPage() do
                        TotalFriends += 1
                        if Players:FindFirstChild(Data.Username) then
                            InServer += 1
                        end
                    end

                    if FriendPages.IsFinished then
                        break
                    end

                    FriendPages:AdvanceToNextPageAsync()
                end
            end)

            FriendCache.All = tostring(TotalFriends) .. " friends"
            FriendCache.Online = tostring(OnlineFriends) .. " friends"
            FriendCache.Offline = tostring(math.max(TotalFriends - OnlineFriends, 0)) .. " friends"
            FriendCache.InServer = InServer > 0 and (tostring(InServer) .. " friends") or "no friends"
        end)
    end

    local function UpdateDashboard(DeltaTime: number)
        if not Root.Parent then
            return
        end

        local Now = os.clock()

        for Index = #FrameTimes, 1, -1 do
            if FrameTimes[Index] < Now - 1 then
                table.remove(FrameTimes, Index)
            end
        end
        table.insert(FrameTimes, Now)

        Accumulator += DeltaTime or 0
        if Accumulator < 0.5 then
            return
        end
        Accumulator = 0

        --// Only repaint while the dashboard tab is on screen \\--
        if not Tab.Container.Visible then
            return
        end

        local Ping = "..."
        pcall(function()
            Ping = tostring(math.floor((LocalPlayer:GetNetworkPing() * 1000) + 0.5)) .. "ms"
        end)

        SetText(Welcome, "Hello, " .. tostring(LocalPlayer.DisplayName))
        SetText(Username, GetGreeting(Config.Greetings) .. " | @" .. tostring(LocalPlayer.Name))
        SetText(StatLabels.Players, tostring(#Players:GetPlayers()) .. " playing")
        SetText(StatLabels.Capacity, tostring(Players.MaxPlayers) .. " can join")
        SetText(StatLabels.Latency, Ping)
        SetText(StatLabels.FPS, tostring(#FrameTimes) .. " fps")
        SetText(StatLabels.Region, tostring(Region))
        SetText(StatLabels.Runtime, GetElapsed(StartedAt))

        SetText(FriendLabels.InServer, FriendCache.InServer)
        SetText(FriendLabels.Offline, FriendCache.Offline)
        SetText(FriendLabels.Online, FriendCache.Online)
        SetText(FriendLabels.All, FriendCache.All)

        UpdateFriends()
    end

    local RenderConnection = RunService.RenderStepped:Connect(UpdateDashboard)
    if Library.GiveSignal then
        Library:GiveSignal(RenderConnection)
    end

    --// Dashboard API \\--
    local Dashboard = {
        Tab = Tab,
        Window = Window,
        Root = Root,
        Frame = Root,
        ActivePage = "Details",
        Connections = { RenderConnection },
        Music = MusicAPI,
    }

    function Dashboard:SelectPage(PageName: string)
        if Pages[PageName] then
            SelectPage(PageName)
            Dashboard.ActivePage = PageName
        end
    end

    function Dashboard:Destroy()
        if RenderConnection and RenderConnection.Connected then
            RenderConnection:Disconnect()
        end

        if MusicAPI and MusicAPI.Destroy then
            MusicAPI.Destroy()
        end

        if Root and Root.Parent then
            Root:Destroy()
        end

        for Side, WasVisible in OriginalSidesVisible do
            pcall(function()
                Side.Visible = WasVisible
            end)
        end

        table.clear(Dashboard.Connections)

        DashboardManager.Dashboard = nil
        DashboardManager.AppliedToTab = false
    end

    if Library.OnUnload then
        Library:OnUnload(function()
            Dashboard:Destroy()
        end)
    end

    DashboardManager.Dashboard = Dashboard
    DashboardManager.AppliedToTab = true

    return Dashboard
end

--// Creates the dashboard tab on a window and builds the dashboard into it \\--
function DashboardManager:CreateDashboardTab(Window: any, Config: any)
    local Library = DashboardManager.Library
    assert(Library, "Library is not set, call DashboardManager:SetLibrary(Library) first.")
    assert(typeof(Window) == "table" and Window.AddTab, "Expected a valid Window for the dashboard.")

    Config = Library:Validate(Config or {}, Defaults)

    local Tab = Window:AddTab({
        Name = Config.Title or Config.Name,
        Icon = Config.Icon,
        Description = Config.Description,
        Order = Config.Order,
    })

    return Tab, DashboardManager:CreateDashboard(Tab, Config)
end

function DashboardManager:ApplyToTab(Tab: any, Config: any)
    return DashboardManager:CreateDashboard(Tab, Config)
end

function DashboardManager:ApplyToWindow(Window: any, Config: any)
    return DashboardManager:CreateDashboardTab(Window, Config)
end

getgenv().ObsidianDashboardManager = DashboardManager
return DashboardManager
