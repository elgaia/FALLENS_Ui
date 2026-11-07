local cloneref = (cloneref or clonereference or function(instance: any)
    return instance
end)

local HttpService: HttpService = cloneref(game:GetService("HttpService"))
local Players: Players = cloneref(game:GetService("Players"))
local RunService: RunService = cloneref(game:GetService("RunService"))
local TweenService: TweenService = cloneref(game:GetService("TweenService"))
local LocalizationService: LocalizationService = cloneref(game:GetService("LocalizationService"))
local MarketplaceService: MarketplaceService = cloneref(game:GetService("MarketplaceService"))
local TeleportService: TeleportService = cloneref(game:GetService("TeleportService"))
local UserInputService: UserInputService = cloneref(game:GetService("UserInputService"))
local SoundService: SoundService = cloneref(game:GetService("SoundService"))
local ContentProvider: ContentProvider = cloneref(game:GetService("ContentProvider"))

local LocalPlayer: Player = Players.LocalPlayer

--// DashboardManager \\--
--// Adds a modern dashboard tab similar to modern UI dashboards: profile card (avatar +
--// greeting), segment bar, server / discord / executor / friends cards with live stats and
--// custom segment pages (changelog, script info, ...), plus a built-in music player segment
--// styled like the details & info page: play / pause / stop, prev / next, seek bar, volume
--// & speed sliders, playlist with asset ids and local .mp3 files, loop & shuffle modes and
--// an auto scan that creates FALLENS/music and loads every .mp3 inside it on load.
--// The details & info page also carries the server tools: a tap-to-copy Job ID row,
--// server hop, small server hopping, join by Job ID and a privacy toggle that hides the
--// username & display name locally (dashboard texts + the name above your own character).
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

--// Copies text through whichever clipboard function the executor exposes \\--
local function CopyToClipboard(Text: string): boolean
    if setclipboard then
        setclipboard(Text)
        return true
    elseif toclipboard then
        toclipboard(Text)
        return true
    elseif set_clipboard then
        set_clipboard(Text)
        return true
    end

    return false
end

--// Accepts a raw job id, a roblox.com server link (?jobId= / gameId=) or any text with a
--// GUID inside it and returns the job id itself \\--
local function ExtractJobId(Input: any): string?
    local Text = tostring(Input or "")

    local FromLink = Text:match("[?&]jobId=([%w%-]+)") or Text:match("[?&]gameId=([%w%-]+)")
    if FromLink then
        return FromLink
    end

    local Guid = Text:match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)")
    if Guid then
        return Guid
    end

    --// Loose fallback for ids that only survived as a dashed hex blob \\--
    local Token = Trim(Text):match("^(%x[%x%-]+)$")
    if Token and #Token >= 32 then
        return Token
    end

    return nil
end

--// Server utilities used by the details & info page (job id copy, server hop,
--// small server hopping and joining a server by job id) \\--
local function GetCurrentJobId(): string
    return tostring(game.JobId or "")
end

--// Pulls joinable public servers from the games api and skips the current instance.
--// sortOrder=Asc lists the least populated servers first, which keeps the small server
--// pick accurate even when only a single page gets fetched \\--
local function FetchPublicServers(MaxPages: number): { [number]: any }
    local Servers = {}
    local Cursor: string? = nil

    for _ = 1, math.max(1, MaxPages or 1) do
        local Url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100&excludeFullGames=true")
            :format(game.PlaceId)
        if Cursor then
            Url = Url .. "&cursor=" .. HttpService:UrlEncode(Cursor)
        end

        local Success, Body = pcall(function()
            return game:HttpGet(Url)
        end)
        if not Success or typeof(Body) ~= "string" or Body == "" then
            break
        end

        local Decoded, Data = pcall(HttpService.JSONDecode, HttpService, Body)
        if not Decoded or typeof(Data) ~= "table" or typeof(Data.data) ~= "table" then
            break
        end

        for _, Server in Data.data do
            if
                typeof(Server) == "table"
                and typeof(Server.id) == "string"
                and Server.id ~= GetCurrentJobId()
                and (tonumber(Server.playing) or 0) < (tonumber(Server.maxPlayers) or math.huge)
            then
                table.insert(Servers, Server)
            end
        end

        Cursor = typeof(Data.nextPageCursor) == "string" and Data.nextPageCursor or nil
        if not Cursor then
            break
        end
    end

    return Servers
end

--// Joins the server behind a job id, returns false + the error message on failure \\--
local function TeleportToJobId(JobId: string): (boolean, string)
    local Ok, Err = pcall(function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, JobId, LocalPlayer)
    end)
    return Ok, tostring(Err or "")
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

    ShowMusicSegment = true,
    MusicText = "Music Player",
    MusicIcon = "music",
    MusicVolume = 50,
    MusicSpeed = 1,

    DiscordInvite = "",
    SupportedExecutors = {},
    UnsupportedExecutors = {},
    Segments = nil,

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

--// Swaps a lib icon in place and keeps the theme registry in sync (play / pause button)
local function SwapIcon(Library, Icon: GuiObject, IconName: string, SchemeName: string): GuiObject
    local NewIcon = Library:GetCustomIcon(IconName)
    if NewIcon then
        Icon = Library:ApplyIcon(Icon, NewIcon)
    end

    SetIconColorScheme(Library, Icon, SchemeName)
    return Icon
end

--// Recolors a text label and keeps the theme registry in sync
local function SetLabelScheme(Library, Label: any, SchemeName: string)
    if Label and Label.Parent then
        Label.TextColor3 = Library.Scheme[SchemeName]
        if Library.Registry[Label] then
            Library.Registry[Label].TextColor3 = SchemeName
        end
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

--// Action button laid out on the stat grid (server hop / small server / join server and
--// the privacy toggle); mirrors the music player pills while keeping the stat spacing.
--// GetState lets toggle styled buttons keep their accent state through hover tweens \\--
local function MakeActionButton(
    Library,
    Parent: GuiObject,
    Text: string,
    IconName: string,
    X: number,
    Y: number,
    W: number,
    GetState
): (TextButton, GuiObject, TextLabel)
    local Button = Instance.new("TextButton")
    Button.BackgroundColor3 = Library.Scheme.BackgroundColor
    Button.BackgroundTransparency = 0.25
    Button.BorderSizePixel = 0
    Button.AutoButtonColor = false
    Button.Text = ""
    Button.Size = UDim2.new(W, -6, 0, 42)
    Button.Position = UDim2.new(X, 3, 0, Y)
    Button.ClipsDescendants = true
    Button.Parent = Parent

    Library:AddToRegistry(Button, { BackgroundColor3 = "BackgroundColor" })
    MakeCorner(Library, Button, 4)

    local Inner = Instance.new("Frame")
    Inner.AnchorPoint = Vector2.new(0.5, 0.5)
    Inner.BackgroundTransparency = 1
    Inner.BorderSizePixel = 0
    Inner.Position = UDim2.fromScale(0.5, 0.5)
    Inner.Size = UDim2.new(1, -24, 1, 0)
    Inner.Parent = Button

    local InnerLayout = Instance.new("UIListLayout")
    InnerLayout.FillDirection = Enum.FillDirection.Horizontal
    InnerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    InnerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    InnerLayout.SortOrder = Enum.SortOrder.LayoutOrder
    InnerLayout.Padding = UDim.new(0, 6)
    InnerLayout.Parent = Inner

    --// Accent icon makes the pill read as an action button \\--
    local Icon = MakeIcon(Library, Button, IconName, 15, "AccentColor")
    Icon.Parent = Inner
    Icon.LayoutOrder = 1

    local Label = MakeText(Library, Button, Text, 11, true, 0.25)
    Label.Parent = Inner
    Label.LayoutOrder = 2
    Label.TextXAlignment = Enum.TextXAlignment.Left

    --// Measure the label so it hugs its text, a scale-sized label stretches to the
    --// full pill width and pushes the icon out of the button (clipped, off-center) \\--
    local TextWidth = select(1, Library:GetTextBounds(Text, Library.Scheme.Font, 11))
    Label.Size = UDim2.new(0, math.max(24, TextWidth + 2), 0, 17)

    Button.MouseEnter:Connect(function()
        local HoverTarget = 0.1
        if GetState and GetState() then
            HoverTarget = 0
        end
        TweenService:Create(Button, Library.TweenInfo, { BackgroundTransparency = HoverTarget }):Play()
    end)
    Button.MouseLeave:Connect(function()
        local RestTarget = 0.25
        if GetState and GetState() then
            RestTarget = 0.1
        end
        TweenService:Create(Button, Library.TweenInfo, { BackgroundTransparency = RestTarget }):Play()
    end)

    return Button, Icon, Label
end

--// Segment page with description entries (Title / Date / Content) \\--
local function FillDescription(Library, Page: GuiObject, Description: any, EmptyText: string)
    local Scroll = Instance.new("ScrollingFrame")
    Scroll.BackgroundTransparency = 1
    Scroll.Size = UDim2.fromScale(1, 1)
    Scroll.CanvasSize = UDim2.fromOffset(0, 0)
    Scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    Scroll.ScrollBarThickness = 2
    Scroll.ScrollingDirection = Enum.ScrollingDirection.Y
    Scroll.BorderSizePixel = 0
    Scroll.Parent = Page

    local Holder = Instance.new("Frame")
    Holder.BackgroundTransparency = 1
    Holder.Size = UDim2.new(1, 0, 0, 0)
    Holder.AutomaticSize = Enum.AutomaticSize.Y
    Holder.Parent = Scroll

    local Layout = Instance.new("UIListLayout")
    Layout.SortOrder = Enum.SortOrder.LayoutOrder
    Layout.Padding = UDim.new(0, 8)
    Layout.Parent = Holder

    local Padding = Instance.new("UIPadding")
    Padding.PaddingTop = UDim.new(0, 4)
    Padding.PaddingBottom = UDim.new(0, 4)
    Padding.PaddingLeft = UDim.new(0, 2)
    Padding.PaddingRight = UDim.new(0, 2)
    Padding.Parent = Holder

    if typeof(Description) ~= "table" then
        Description = {}
    end

    local Entries = Description
    --// A single entry can also be passed directly instead of a list
    if Description.Title ~= nil or Description.Content ~= nil then
        Entries = { Description }
    end

    local HasContent = false
    for _, _Entry in Entries do
        HasContent = true
        break
    end

    if not HasContent then
        local Empty = MakeText(Library, Holder, EmptyText, 13, false, 0.25)
        Empty.Size = UDim2.new(1, 0, 0, 26)
        Empty.TextXAlignment = Enum.TextXAlignment.Center
        return
    end

    for Index, Entry in Entries do
        if typeof(Entry) ~= "table" then
            Entry = { Content = tostring(Entry) }
        end

        local Item = MakePanel(Library, Holder, UDim2.new(1, 0, 0, 0))
        Item.AutomaticSize = Enum.AutomaticSize.Y
        Item.ClipsDescendants = false
        Item.LayoutOrder = Index

        local ItemLayout = Instance.new("UIListLayout")
        ItemLayout.SortOrder = Enum.SortOrder.LayoutOrder
        ItemLayout.Padding = UDim.new(0, 4)
        ItemLayout.Parent = Item

        local ItemPadding = Instance.new("UIPadding")
        ItemPadding.PaddingTop = UDim.new(0, 10)
        ItemPadding.PaddingBottom = UDim.new(0, 10)
        ItemPadding.PaddingLeft = UDim.new(0, 12)
        ItemPadding.PaddingRight = UDim.new(0, 12)
        ItemPadding.Parent = Item

        --// Header row: Title + Date
        local HeaderRow = Instance.new("Frame")
        HeaderRow.BackgroundTransparency = 1
        HeaderRow.Size = UDim2.new(1, 0, 0, 18)
        HeaderRow.LayoutOrder = 1
        HeaderRow.Parent = Item

        local TitleLabel = MakeText(Library, HeaderRow, tostring(Entry.Title or Entry.Name or ""), 13, true, 0)
        TitleLabel.Size = UDim2.new(1, -70, 1, 0)

        if Entry.Date then
            local DateLabel = MakeText(Library, HeaderRow, tostring(Entry.Date), 10, false, 0.45)
            DateLabel.AnchorPoint = Vector2.new(1, 0.5)
            DateLabel.Position = UDim2.new(1, 0, 0.5, 0)
            DateLabel.Size = UDim2.fromOffset(65, 14)
            DateLabel.TextXAlignment = Enum.TextXAlignment.Right
        end

        local ContentText = tostring(Entry.Content or Entry.Description or "")
        ContentText = ContentText:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\n%s+", "\n")

        if ContentText ~= "" then
            local Desc = MakeText(Library, Item, ContentText, 11, false, 0.25)
            Desc.Size = UDim2.new(1, 0, 0, 0)
            Desc.AutomaticSize = Enum.AutomaticSize.Y
            Desc.TextWrapped = true
            Desc.TextTruncate = Enum.TextTruncate.None
            Desc.TextYAlignment = Enum.TextYAlignment.Top
            Desc.RichText = Entry.RichText ~= false
            Desc.LayoutOrder = 2
        end
    end
end

--// Music player segment (cards styled like the details & info page) \\--
local function FormatMusicTime(Seconds: number): string
    Seconds = math.max(0, math.floor((tonumber(Seconds) or 0) + 0.5))
    return string.format("%d:%02d", math.floor(Seconds / 60), Seconds % 60)
end

--// Dedicated music folder inside the executor workspace: it is created automatically on
--// load and every .mp3 / .ogg inside it is added to the playlist (subfolders included) \\--
local MUSIC_FOLDER = "FALLENS/music"

--// Older spellings of the folder are still scanned read-only, so songs dropped there
--// before the rename keep loading; nothing is ever written into them \\--
local MUSIC_FOLDER_ALIASES = { "workspace/FALLENS/music", "workspace.FALLENS.music" }

--// Markers used to recognize music folder entries, listfiles can return bare names,
--// "workspace/..." relative paths or full windows paths depending on the executor \\--
local MUSIC_MARKERS = { "fallens/music/", "fallens.music/" }

local function IsAudioFile(Name: string): boolean
    local Lower = tostring(Name):lower()
    return Lower:match("%.mp3$") ~= nil or Lower:match("%.ogg$") ~= nil
end

--// Strips everything up to the music folder and returns the path inside it, or nil when
--// the entry does not point inside FALLENS/music \\--
local function ToMusicRelative(Entry: any): string?
    local Path = tostring(Entry):gsub("\\", "/")
    local Lower = Path:lower()
    for _, Marker in MUSIC_MARKERS do
        local At = Lower:find(Marker, 1, true)
        if At then
            local Relative = Path:sub(At + #Marker)
            if Relative ~= "" then
                return Relative
            end
        end
    end
    return nil
end

--// Creates FALLENS/music when it is missing (one level at a time because some
--// executors refuse nested creation). Returns true when the folder was created just now \\--
local function EnsureMusicFolder(): boolean
    if typeof(makefolder) ~= "function" then
        return false
    end

    if typeof(isfolder) == "function" and isfolder(MUSIC_FOLDER) then
        return false
    end

    local Path = ""
    for Segment in MUSIC_FOLDER:gmatch("[^/]+") do
        Path = Path == "" and Segment or (Path .. "/" .. Segment)
        if typeof(isfolder) ~= "function" or not isfolder(Path) then
            pcall(makefolder, Path)
        end
    end

    return typeof(isfolder) ~= "function" or isfolder(MUSIC_FOLDER)
end

local function CreateMusicPlayer(Library, Page: GuiObject, Options: { [string]: any })
    local Mouse = LocalPlayer:GetMouse()
    local CardGap = tonumber(Options.CardGap) or 10
    local Compact = Library.IsMobile == true

    --// Playback state \\--
    local Playlist: { { [string]: any } } = {}
    local CurrentIndex = 0
    local PlaybackState = "Stopped" --// Stopped | Playing | Paused
    local LoopPlaylist = false
    local Shuffle = false
    local SwitchingSongs = false
    local LastAdvanceAt = 0
    local ConsecutiveFailures = 0
    local Volume = math.floor(math.clamp(tonumber(Options.Volume) or 50, 0, 100) + 0.5)
    local Speed = math.clamp(tonumber(Options.Speed) or 1, 0.25, 3)
    local Connections: { RBXScriptConnection } = {}
    local Draggers: { { [string]: any } } = {}

    local function Notify(Title: string, Description: string)
        if Library.Notify then
            Library:Notify({ Title = Title, Description = Description, Time = 3 })
        end
    end

    local Sound = Instance.new("Sound")
    Sound.Name = "FALLENS_DashboardMusic"
    Sound.Volume = Volume / 100
    Sound.PlaybackSpeed = Speed
    Sound.Parent = SoundService

    --// Forward declarations, the player functions reference each other \\--
    local PlayIndex, RefreshPlaylist, RemoveSong, TogglePlay, StopSong, NextSong, PrevSong, AutoAdvance
    local UpdateNowPlaying

    --// Shared drag plumbing for the seek / volume / speed bars \\--
    local function AddDragger(Dragger: { [string]: any }): { [string]: any }
        Dragger.Dragging = false
        table.insert(Draggers, Dragger)
        return Dragger
    end

    local function BeginDrag(Dragger: { [string]: any })
        Dragger.Dragging = true
        if Options.SetScrolling then
            Options.SetScrolling(false)
        end
        Dragger.UpdateFromMouse()
    end

    table.insert(Connections, UserInputService.InputChanged:Connect(function(Input)
        if Input.UserInputType == Enum.UserInputType.MouseMovement or Input.UserInputType == Enum.UserInputType.Touch then
            for _, Dragger in Draggers do
                if Dragger.Dragging then
                    Dragger.UpdateFromMouse()
                end
            end
        end
    end))

    table.insert(Connections, UserInputService.InputEnded:Connect(function(Input)
        if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
            local WasDragging = false

            for _, Dragger in Draggers do
                if Dragger.Dragging then
                    Dragger.Dragging = false
                    WasDragging = true
                    if Dragger.OnRelease then
                        Dragger.OnRelease()
                    end
                end
            end

            if WasDragging and Options.SetScrolling then
                Options.SetScrolling(true)
            end
        end
    end))

    --// Columns, same split as the details page \\--
    local LeftColumn = Instance.new("Frame")
    LeftColumn.BackgroundTransparency = 1
    LeftColumn.BorderSizePixel = 0
    LeftColumn.Size = UDim2.new(0.52, -4, 1, 0)
    LeftColumn.Parent = Page

    local LeftColumnLayout = Instance.new("UIListLayout")
    LeftColumnLayout.SortOrder = Enum.SortOrder.LayoutOrder
    LeftColumnLayout.Padding = UDim.new(0, CardGap)
    LeftColumnLayout.Parent = LeftColumn

    local RightColumn = Instance.new("Frame")
    RightColumn.BackgroundTransparency = 1
    RightColumn.BorderSizePixel = 0
    RightColumn.Position = UDim2.new(0.52, 4, 0, 0)
    RightColumn.Size = UDim2.new(0.48, -4, 1, 0)
    RightColumn.Parent = Page

    local RightColumnLayout = Instance.new("UIListLayout")
    RightColumnLayout.SortOrder = Enum.SortOrder.LayoutOrder
    RightColumnLayout.Padding = UDim.new(0, CardGap)
    RightColumnLayout.Parent = RightColumn

    --// Transport button (prev / play / stop / next) \\--
    local function MakeControlButton(Parent: GuiObject, Width: number, IconName: string, Accent: boolean?)
        local Button = Instance.new("TextButton")
        Button.BackgroundColor3 = Accent and Library.Scheme.AccentColor or Library.Scheme.BackgroundColor
        Button.BackgroundTransparency = Accent and 0.1 or 0.25
        Button.BorderSizePixel = 0
        Button.AutoButtonColor = false
        Button.Text = ""
        Button.Size = UDim2.fromOffset(Width, 36)
        Button.ClipsDescendants = true
        Button.Parent = Parent

        Library:AddToRegistry(Button, { BackgroundColor3 = Accent and "AccentColor" or "BackgroundColor" })
        MakeCorner(Library, Button, Library.CornerRadius, true)
        MakeStroke(Library, Button)

        local Icon = MakeIcon(Library, Button, IconName, 16, Accent and "WhiteColor" or "FontColor")
        Icon.AnchorPoint = Vector2.new(0.5, 0.5)
        Icon.Position = UDim2.fromScale(0.5, 0.5)

        Button.MouseEnter:Connect(function()
            TweenService:Create(Button, Library.TweenInfo, { BackgroundTransparency = Accent and 0 or 0.1 }):Play()
        end)
        Button.MouseLeave:Connect(function()
            TweenService:Create(Button, Library.TweenInfo, { BackgroundTransparency = Accent and 0.1 or 0.25 }):Play()
        end)

        return Button, Icon
    end

    --// Loop / shuffle mode toggle pill \\--
    local function MakeModeToggle(Parent: GuiObject, IconName: string, Text: string)
        local Button = Instance.new("TextButton")
        Button.BackgroundColor3 = Library.Scheme.BackgroundColor
        Button.BackgroundTransparency = 0.25
        Button.BorderSizePixel = 0
        Button.AutoButtonColor = false
        Button.Text = ""
        Button.Size = UDim2.new(0.5, -4, 1, 0)
        Button.ClipsDescendants = true
        Button.Parent = Parent

        Library:AddToRegistry(Button, { BackgroundColor3 = "BackgroundColor" })
        MakeCorner(Library, Button, Library.CornerRadius, true)
        MakeStroke(Library, Button)

        local Inner = Instance.new("Frame")
        Inner.AnchorPoint = Vector2.new(0.5, 0.5)
        Inner.BackgroundTransparency = 1
        Inner.BorderSizePixel = 0
        Inner.Position = UDim2.fromScale(0.5, 0.5)
        Inner.Size = UDim2.new(1, -12, 1, 0)
        Inner.Parent = Button

        local InnerLayout = Instance.new("UIListLayout")
        InnerLayout.FillDirection = Enum.FillDirection.Horizontal
        InnerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        InnerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
        InnerLayout.SortOrder = Enum.SortOrder.LayoutOrder
        InnerLayout.Padding = UDim.new(0, 6)
        InnerLayout.Parent = Inner

        local Icon = MakeIcon(Library, Button, IconName, 14, "FontColor")
        Icon.Parent = Inner
        Icon.LayoutOrder = 1

        local Label = MakeText(Library, Button, Text, 11, true, 0.25)
        Label.Parent = Inner
        Label.LayoutOrder = 2
        Label.TextXAlignment = Enum.TextXAlignment.Left

        --// Measure the label so it hugs its text: a scale-sized label stretches to the
        --// full pill width and pushes the icon out of the button (clipped, off-center)
        local TextWidth = select(1, Library:GetTextBounds(Text, Library.Scheme.Font, 11))
        Label.Size = UDim2.new(0, math.max(24, TextWidth + 2), 0, 17)

        --// Status dot on the right edge: dim when off, lit while the mode is on \\--
        local Dot = Instance.new("Frame")
        Dot.BackgroundColor3 = Library.Scheme.OutlineColor
        Dot.BorderSizePixel = 0
        Dot.AnchorPoint = Vector2.new(1, 0.5)
        Dot.Position = UDim2.new(1, -9, 0.5, 0)
        Dot.Size = UDim2.fromOffset(5, 5)
        Dot.Parent = Button

        Library:AddToRegistry(Dot, { BackgroundColor3 = "OutlineColor" })
        local DotCorner = Instance.new("UICorner")
        DotCorner.CornerRadius = UDim.new(1, 0)
        DotCorner.Parent = Dot

        local State = { On = false }

        Button.MouseEnter:Connect(function()
            TweenService:Create(Button, Library.TweenInfo, { BackgroundTransparency = State.On and 0 or 0.15 }):Play()
        end)
        Button.MouseLeave:Connect(function()
            TweenService:Create(Button, Library.TweenInfo, { BackgroundTransparency = State.On and 0.1 or 0.25 }):Play()
        end)

        return Button, Icon, Label, State, Dot
    end

    local function SetModeVisual(
        Button: any,
        Icon: any,
        Label: any,
        State: { [string]: any },
        Dot: any,
        IsOn: boolean
    )
        State.On = IsOn
        Button.BackgroundColor3 = IsOn and Library.Scheme.AccentColor or Library.Scheme.BackgroundColor
        Button.BackgroundTransparency = IsOn and 0.1 or 0.25

        if Library.Registry[Button] then
            Library.Registry[Button].BackgroundColor3 = IsOn and "AccentColor" or "BackgroundColor"
        end

        SetIconColorScheme(Library, Icon, IsOn and "WhiteColor" or "FontColor")
        SetLabelScheme(Library, Label, IsOn and "WhiteColor" or "FontColor")
        Label.TextTransparency = IsOn and 0 or 0.25

        Dot.BackgroundColor3 = IsOn and Library.Scheme.WhiteColor or Library.Scheme.OutlineColor
        if Library.Registry[Dot] then
            Library.Registry[Dot].BackgroundColor3 = IsOn and "WhiteColor" or "OutlineColor"
        end
    end

    --// Generic slider bar (volume / speed) \\--
    local function MakeMusicSlider(
        Parent: GuiObject,
        Y: number,
        Min: number,
        Max: number,
        Step: number,
        Initial: number,
        OnChanged: (number) -> ()
    )
        local Bar = Instance.new("TextButton")
        Bar.BackgroundColor3 = Library.Scheme.BackgroundColor
        Bar.BackgroundTransparency = 0.2
        Bar.BorderSizePixel = 0
        Bar.AutoButtonColor = false
        Bar.Text = ""
        Bar.Size = UDim2.new(1, -28, 0, 12)
        Bar.Position = UDim2.fromOffset(14, Y)
        Bar.Parent = Parent

        Library:AddToRegistry(Bar, { BackgroundColor3 = "BackgroundColor" })
        MakeCorner(Library, Bar, 4)
        MakeStroke(Library, Bar)

        local Fill = Instance.new("Frame")
        Fill.BackgroundColor3 = Library.Scheme.AccentColor
        Fill.BorderSizePixel = 0
        Fill.Size = UDim2.fromScale(math.clamp((Initial - Min) / (Max - Min), 0, 1), 1)
        Fill.Parent = Bar

        Library:AddToRegistry(Fill, { BackgroundColor3 = "AccentColor" })
        MakeCorner(Library, Fill, 4)

        local Value = Initial

        local function Snap(Raw: number): number
            Raw = Min + math.floor((Raw - Min) / Step + 0.5) * Step
            Raw = math.clamp(Raw, Min, Max)
            return tonumber(string.format("%.2f", Raw)) or Raw
        end

        local Dragger = AddDragger({
            UpdateFromMouse = function()
                local Relative = math.clamp((Mouse.X - Bar.AbsolutePosition.X) / math.max(Bar.AbsoluteSize.X, 1), 0, 1)
                Value = Snap(Min + (Max - Min) * Relative)
                Fill.Size = UDim2.fromScale((Value - Min) / (Max - Min), 1)
                OnChanged(Value)
            end,
        })

        Bar.InputBegan:Connect(function(Input)
            if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
                BeginDrag(Dragger)
            end
        end)

        return {
            SetValue = function(Raw: number)
                Value = Snap(Raw)
                Fill.Size = UDim2.fromScale((Value - Min) / (Max - Min), 1)
                OnChanged(Value)
            end,
        }
    end

    --// Text input box (song name / asset id or file name) \\--
    local function MakeInputBox(Parent: GuiObject, Y: number, Placeholder: string): TextBox
        local Box = Instance.new("TextBox")
        Box.BackgroundColor3 = Library.Scheme.BackgroundColor
        Box.BackgroundTransparency = 0.2
        Box.BorderSizePixel = 0
        Box.Size = UDim2.new(1, -28, 0, 24)
        Box.Position = UDim2.fromOffset(14, Y)
        Box.Text = ""
        Box.PlaceholderText = Placeholder
        Box.TextSize = 11
        Box.TextXAlignment = Enum.TextXAlignment.Left
        Box.ClearTextOnFocus = false
        Box.ClipsDescendants = true
        Box.Parent = Parent

        Library:AddToRegistry(Box, { TextColor3 = "FontColor", FontFace = "Font" })
        Box.TextColor3 = Library.Scheme.FontColor
        Box.FontFace = Library.Scheme.Font
        MakeCorner(Library, Box, 4)

        local Stroke = MakeStroke(Library, Box)

        local Padding = Instance.new("UIPadding")
        Padding.PaddingLeft = UDim.new(0, 8)
        Padding.PaddingRight = UDim.new(0, 8)
        Padding.Parent = Box

        Box.Focused:Connect(function()
            Stroke.Color = Library.Scheme.AccentColor
            if Library.Registry[Stroke] then
                Library.Registry[Stroke].Color = "AccentColor"
            end
        end)
        Box.FocusLost:Connect(function()
            Stroke.Color = Library.Scheme.OutlineColor
            if Library.Registry[Stroke] then
                Library.Registry[Stroke].Color = "OutlineColor"
            end
        end)

        return Box
    end

    --// Add music button (asset id / mp3 file) \\--
    local function MakeAddButton(Parent: GuiObject, IconName: string, Text: string): TextButton
        local Button = Instance.new("TextButton")
        Button.BackgroundColor3 = Library.Scheme.BackgroundColor
        Button.BackgroundTransparency = 0.25
        Button.BorderSizePixel = 0
        Button.AutoButtonColor = false
        Button.Text = ""
        Button.Size = UDim2.new(0.5, -4, 1, 0)
        Button.ClipsDescendants = true
        Button.Parent = Parent

        Library:AddToRegistry(Button, { BackgroundColor3 = "BackgroundColor" })
        MakeCorner(Library, Button, Library.CornerRadius, true)
        MakeStroke(Library, Button)

        local Inner = Instance.new("Frame")
        Inner.AnchorPoint = Vector2.new(0.5, 0.5)
        Inner.BackgroundTransparency = 1
        Inner.BorderSizePixel = 0
        Inner.Position = UDim2.fromScale(0.5, 0.5)
        Inner.Size = UDim2.new(1, -10, 1, 0)
        Inner.Parent = Button

        local InnerLayout = Instance.new("UIListLayout")
        InnerLayout.FillDirection = Enum.FillDirection.Horizontal
        InnerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        InnerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
        InnerLayout.SortOrder = Enum.SortOrder.LayoutOrder
        InnerLayout.Padding = UDim.new(0, 6)
        InnerLayout.Parent = Inner

        --// Accent icon makes the pair read as action buttons \\--
        local Icon = MakeIcon(Library, Button, IconName, 14, "AccentColor")
        Icon.Parent = Inner
        Icon.LayoutOrder = 1

        local Label = MakeText(Library, Button, Text, 11, true, 0.25)
        Label.Parent = Inner
        Label.LayoutOrder = 2
        Label.TextXAlignment = Enum.TextXAlignment.Left

        --// Measure the label so it hugs its text: a scale-sized label stretches to the
        --// full pill width and pushes the icon out of the button (clipped, off-center)
        local TextWidth = select(1, Library:GetTextBounds(Text, Library.Scheme.Font, 11))
        Label.Size = UDim2.new(0, math.max(24, TextWidth + 2), 0, 17)

        Button.MouseEnter:Connect(function()
            TweenService:Create(Button, Library.TweenInfo, { BackgroundTransparency = 0.1 }):Play()
        end)
        Button.MouseLeave:Connect(function()
            TweenService:Create(Button, Library.TweenInfo, { BackgroundTransparency = 0.25 }):Play()
        end)

        return Button
    end

    --// Now playing card (left column) \\--
    local NowPlayingCard = MakePanel(Library, LeftColumn, UDim2.new(1, 0, 0, 178))
    NowPlayingCard.LayoutOrder = 1

    local NowPlayingTitle = MakeText(Library, NowPlayingCard, "Now Playing", 15, true, 0)
    NowPlayingTitle.Position = UDim2.fromOffset(14, 12)
    NowPlayingTitle.Size = UDim2.new(1, -96, 0, 18)

    local StatusLabel = MakeText(Library, NowPlayingCard, "Stopped", 10, false, 0.45)
    StatusLabel.AnchorPoint = Vector2.new(1, 0)
    StatusLabel.Position = UDim2.new(1, -14, 0, 15)
    StatusLabel.Size = UDim2.fromOffset(76, 14)
    StatusLabel.TextXAlignment = Enum.TextXAlignment.Right

    local SongLabel = MakeText(Library, NowPlayingCard, "Nothing playing", 13, true, 0.05)
    SongLabel.Position = UDim2.fromOffset(14, 34)
    SongLabel.Size = UDim2.new(1, -28, 0, 17)

    local SongDetail = MakeText(Library, NowPlayingCard, "Add songs from the playlist card", 10, false, 0.45)
    SongDetail.Position = UDim2.fromOffset(14, 53)
    SongDetail.Size = UDim2.new(1, -28, 0, 13)

    --// Seek bar \\--
    local SeekBar = Instance.new("TextButton")
    SeekBar.BackgroundColor3 = Library.Scheme.BackgroundColor
    SeekBar.BackgroundTransparency = 0.2
    SeekBar.BorderSizePixel = 0
    SeekBar.AutoButtonColor = false
    SeekBar.Text = ""
    SeekBar.Size = UDim2.new(1, -28, 0, 14)
    SeekBar.Position = UDim2.fromOffset(14, 70)
    SeekBar.Parent = NowPlayingCard

    Library:AddToRegistry(SeekBar, { BackgroundColor3 = "BackgroundColor" })
    MakeCorner(Library, SeekBar, 4)
    MakeStroke(Library, SeekBar)

    local SeekFill = Instance.new("Frame")
    SeekFill.BackgroundColor3 = Library.Scheme.AccentColor
    SeekFill.BorderSizePixel = 0
    SeekFill.Size = UDim2.fromScale(0, 1)
    SeekFill.ZIndex = 2
    SeekFill.Parent = SeekBar

    Library:AddToRegistry(SeekFill, { BackgroundColor3 = "AccentColor" })
    MakeCorner(Library, SeekFill, 4)

    local SeekKnob = Instance.new("Frame")
    SeekKnob.BackgroundColor3 = Library.Scheme.WhiteColor
    SeekKnob.BorderSizePixel = 0
    SeekKnob.AnchorPoint = Vector2.new(0.5, 0.5)
    SeekKnob.Position = UDim2.new(0, 0, 0.5, 0)
    SeekKnob.Size = UDim2.fromOffset(10, 10)
    SeekKnob.ZIndex = 3
    SeekKnob.Parent = SeekBar

    Library:AddToRegistry(SeekKnob, { BackgroundColor3 = "WhiteColor" })
    local SeekKnobCorner = Instance.new("UICorner")
    SeekKnobCorner.CornerRadius = UDim.new(1, 0)
    SeekKnobCorner.Parent = SeekKnob

    local TimeCurrent = MakeText(Library, NowPlayingCard, "0:00", 9, false, 0.45)
    TimeCurrent.Position = UDim2.fromOffset(14, 87)
    TimeCurrent.Size = UDim2.fromOffset(70, 12)

    local TimeTotal = MakeText(Library, NowPlayingCard, "--:--", 9, false, 0.45)
    TimeTotal.AnchorPoint = Vector2.new(1, 0)
    TimeTotal.Position = UDim2.new(1, -14, 0, 87)
    TimeTotal.Size = UDim2.fromOffset(70, 12)
    TimeTotal.TextXAlignment = Enum.TextXAlignment.Right

    --// Transport row: prev / play-pause / stop / next \\--
    local TransportRow = Instance.new("Frame")
    TransportRow.BackgroundTransparency = 1
    TransportRow.BorderSizePixel = 0
    TransportRow.Position = UDim2.fromOffset(0, 104)
    TransportRow.Size = UDim2.new(1, 0, 0, 36)
    TransportRow.Parent = NowPlayingCard

    local TransportLayout = Instance.new("UIListLayout")
    TransportLayout.FillDirection = Enum.FillDirection.Horizontal
    TransportLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    TransportLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    TransportLayout.SortOrder = Enum.SortOrder.LayoutOrder
    TransportLayout.Padding = UDim.new(0, 8)
    TransportLayout.Parent = TransportRow

    local ControlWidth = Compact and 34 or 40
    local PlayWidth = Compact and 48 or 58

    local PrevButton = MakeControlButton(TransportRow, ControlWidth, "skip-back", false)
    PrevButton.LayoutOrder = 1

    local PlayPauseButton, PlayPauseIcon = MakeControlButton(TransportRow, PlayWidth, "play", true)
    PlayPauseButton.LayoutOrder = 2

    local StopButton = MakeControlButton(TransportRow, ControlWidth, "square", false)
    StopButton.LayoutOrder = 3

    local NextButton = MakeControlButton(TransportRow, ControlWidth, "skip-forward", false)
    NextButton.LayoutOrder = 4

    --// Mode row: loop / shuffle (mirrors the add buttons row layout) \\--
    local ModeRow = Instance.new("Frame")
    ModeRow.BackgroundTransparency = 1
    ModeRow.BorderSizePixel = 0
    ModeRow.Position = UDim2.fromOffset(14, 146)
    ModeRow.Size = UDim2.new(1, -28, 0, 28)
    ModeRow.Parent = NowPlayingCard

    local ModeLayout = Instance.new("UIListLayout")
    ModeLayout.FillDirection = Enum.FillDirection.Horizontal
    ModeLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    ModeLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    ModeLayout.SortOrder = Enum.SortOrder.LayoutOrder
    ModeLayout.Padding = UDim.new(0, 8)
    ModeLayout.Parent = ModeRow

    local LoopButton, LoopIcon, LoopLabel, LoopState, LoopDot =
        MakeModeToggle(ModeRow, "repeat", "Loop")
    LoopButton.LayoutOrder = 1
    local ShuffleButton, ShuffleIcon, ShuffleLabel, ShuffleState, ShuffleDot =
        MakeModeToggle(ModeRow, "shuffle", "Shuffle")
    ShuffleButton.LayoutOrder = 2

    --// Audio card (left column) \\--
    local AudioCard = MakePanel(Library, LeftColumn, UDim2.new(1, 0, 0, 122))
    AudioCard.LayoutOrder = 2

    local AudioTitle = MakeText(Library, AudioCard, "Audio", 15, true, 0)
    AudioTitle.Position = UDim2.fromOffset(14, 12)
    AudioTitle.Size = UDim2.new(1, -28, 0, 18)

    local VolumeIcon = MakeIcon(Library, AudioCard, "volume-2", 14, "FontColor")
    VolumeIcon.Position = UDim2.fromOffset(14, 39)

    local VolumeLabel = MakeText(Library, AudioCard, "Volume", 11, false, 0.35)
    VolumeLabel.Position = UDim2.fromOffset(35, 38)
    VolumeLabel.Size = UDim2.new(1, -110, 0, 15)

    local VolumeValue = MakeText(Library, AudioCard, tostring(Volume) .. "%", 11, true, 0)
    VolumeValue.AnchorPoint = Vector2.new(1, 0)
    VolumeValue.Position = UDim2.new(1, -14, 0, 38)
    VolumeValue.Size = UDim2.fromOffset(70, 15)
    VolumeValue.TextXAlignment = Enum.TextXAlignment.Right
    SetLabelScheme(Library, VolumeValue, "AccentColor")

    local VolumeSlider = MakeMusicSlider(AudioCard, 58, 0, 100, 1, Volume, function(Value: number)
        Volume = Value
        Sound.Volume = Value / 100
        SetText(VolumeValue, tostring(Value) .. "%")
    end)

    local SpeedIcon = MakeIcon(Library, AudioCard, "gauge", 14, "FontColor")
    SpeedIcon.Position = UDim2.fromOffset(14, 79)

    local SpeedLabel = MakeText(Library, AudioCard, "Speed / Pitch", 11, false, 0.35)
    SpeedLabel.Position = UDim2.fromOffset(35, 78)
    SpeedLabel.Size = UDim2.new(1, -110, 0, 15)

    local SpeedValue = MakeText(Library, AudioCard, string.format("%.2fx", Speed), 11, true, 0)
    SpeedValue.AnchorPoint = Vector2.new(1, 0)
    SpeedValue.Position = UDim2.new(1, -14, 0, 78)
    SpeedValue.Size = UDim2.fromOffset(70, 15)
    SpeedValue.TextXAlignment = Enum.TextXAlignment.Right
    SetLabelScheme(Library, SpeedValue, "AccentColor")

    local SpeedSlider = MakeMusicSlider(AudioCard, 96, 0.25, 3, 0.05, Speed, function(Value: number)
        Speed = Value
        Sound.PlaybackSpeed = Value
        SetText(SpeedValue, string.format("%.2fx", Value))
    end)

    --// Add music card (right column) \\--
    local AddCard = MakePanel(Library, RightColumn, UDim2.new(1, 0, 0, 146))
    AddCard.LayoutOrder = 1

    local AddTitle = MakeText(Library, AddCard, "Add Music", 15, true, 0)
    AddTitle.Position = UDim2.fromOffset(14, 12)
    AddTitle.Size = UDim2.new(1, -100, 0, 18)

    --// Folder hint: tells the user where the auto-scanned music folder lives \\--
    local AddFolderHint = MakeText(Library, AddCard, "Folder: " .. MUSIC_FOLDER, 10, false, 0.45)
    AddFolderHint.Position = UDim2.fromOffset(14, 31)
    AddFolderHint.Size = UDim2.new(1, -100, 0, 13)

    --// Rescan button: re-reads every .mp3 from FALLENS/music \\--
    local RescanButton = Instance.new("TextButton")
    RescanButton.BackgroundColor3 = Library.Scheme.BackgroundColor
    RescanButton.BackgroundTransparency = 0.35
    RescanButton.BorderSizePixel = 0
    RescanButton.AutoButtonColor = false
    RescanButton.Text = ""
    RescanButton.AnchorPoint = Vector2.new(1, 0)
    RescanButton.Position = UDim2.new(1, -14, 0, 11)
    RescanButton.Size = UDim2.fromOffset(70, 20)
    RescanButton.ClipsDescendants = true
    RescanButton.Parent = AddCard

    Library:AddToRegistry(RescanButton, { BackgroundColor3 = "BackgroundColor" })
    MakeCorner(Library, RescanButton, 4)
    MakeStroke(Library, RescanButton)

    local RescanInner = Instance.new("Frame")
    RescanInner.AnchorPoint = Vector2.new(0.5, 0.5)
    RescanInner.BackgroundTransparency = 1
    RescanInner.BorderSizePixel = 0
    RescanInner.Position = UDim2.fromScale(0.5, 0.5)
    RescanInner.Size = UDim2.new(1, -4, 1, 0)
    RescanInner.Parent = RescanButton

    local RescanInnerLayout = Instance.new("UIListLayout")
    RescanInnerLayout.FillDirection = Enum.FillDirection.Horizontal
    RescanInnerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    RescanInnerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    RescanInnerLayout.SortOrder = Enum.SortOrder.LayoutOrder
    RescanInnerLayout.Padding = UDim.new(0, 5)
    RescanInnerLayout.Parent = RescanInner

    local RescanIcon = MakeIcon(Library, RescanButton, "refresh-cw", 12, "FontColor")
    RescanIcon.Parent = RescanInner
    RescanIcon.LayoutOrder = 1

    local RescanLabel = MakeText(Library, RescanButton, "Rescan", 10, true, 0.35)
    RescanLabel.Parent = RescanInner
    RescanLabel.LayoutOrder = 2
    RescanLabel.TextXAlignment = Enum.TextXAlignment.Left

    --// Measure so the icon + label pair stays centered inside the pill \\--
    local RescanTextWidth = select(1, Library:GetTextBounds("Rescan", Library.Scheme.Font, 10))
    RescanLabel.Size = UDim2.new(0, math.max(20, RescanTextWidth + 2), 0, 15)

    RescanButton.MouseEnter:Connect(function()
        SetIconColorScheme(Library, RescanIcon, "AccentColor")
        TweenService:Create(RescanButton, Library.TweenInfo, { BackgroundTransparency = 0.15 }):Play()
    end)
    RescanButton.MouseLeave:Connect(function()
        SetIconColorScheme(Library, RescanIcon, "FontColor")
        TweenService:Create(RescanButton, Library.TweenInfo, { BackgroundTransparency = 0.35 }):Play()
    end)

    local NameBox = MakeInputBox(AddCard, 50, "Song name (optional)")
    local SourceBox = MakeInputBox(AddCard, 80, "Asset ID or file name like song.mp3")

    local AddButtonsRow = Instance.new("Frame")
    AddButtonsRow.BackgroundTransparency = 1
    AddButtonsRow.BorderSizePixel = 0
    AddButtonsRow.Position = UDim2.fromOffset(14, 112)
    AddButtonsRow.Size = UDim2.new(1, -28, 0, 24)
    AddButtonsRow.Parent = AddCard

    local AddButtonsLayout = Instance.new("UIListLayout")
    AddButtonsLayout.FillDirection = Enum.FillDirection.Horizontal
    AddButtonsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    AddButtonsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    AddButtonsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    AddButtonsLayout.Padding = UDim.new(0, 8)
    AddButtonsLayout.Parent = AddButtonsRow

    local AddAssetButton = MakeAddButton(AddButtonsRow, "disc", "Asset ID")
    local AddFileButton = MakeAddButton(AddButtonsRow, "file-audio", "MP3 File")

    --// Playlist card (right column) \\--
    local PlaylistCard = MakePanel(Library, RightColumn, UDim2.new(1, 0, 0, 174))
    PlaylistCard.LayoutOrder = 2

    local PlaylistTitle = MakeText(Library, PlaylistCard, "Playlist", 15, true, 0)
    PlaylistTitle.Position = UDim2.fromOffset(14, 12)
    PlaylistTitle.Size = UDim2.new(1, -110, 0, 18)

    local CountLabel = MakeText(Library, PlaylistCard, "0 songs", 10, false, 0.45)
    CountLabel.AnchorPoint = Vector2.new(1, 0)
    CountLabel.Position = UDim2.new(1, -82, 0, 15)
    CountLabel.Size = UDim2.fromOffset(64, 14)
    CountLabel.TextXAlignment = Enum.TextXAlignment.Right

    local ClearButton = Instance.new("TextButton")
    ClearButton.BackgroundColor3 = Library.Scheme.BackgroundColor
    ClearButton.BackgroundTransparency = 0.35
    ClearButton.BorderSizePixel = 0
    ClearButton.AutoButtonColor = false
    ClearButton.Text = ""
    ClearButton.AnchorPoint = Vector2.new(1, 0)
    ClearButton.Position = UDim2.new(1, -14, 0, 11)
    ClearButton.Size = UDim2.fromOffset(60, 20)
    ClearButton.ClipsDescendants = true
    ClearButton.Parent = PlaylistCard

    Library:AddToRegistry(ClearButton, { BackgroundColor3 = "BackgroundColor" })
    MakeCorner(Library, ClearButton, 4)
    MakeStroke(Library, ClearButton)

    local ClearInner = Instance.new("Frame")
    ClearInner.AnchorPoint = Vector2.new(0.5, 0.5)
    ClearInner.BackgroundTransparency = 1
    ClearInner.BorderSizePixel = 0
    ClearInner.Position = UDim2.fromScale(0.5, 0.5)
    ClearInner.Size = UDim2.new(1, -4, 1, 0)
    ClearInner.Parent = ClearButton

    local ClearInnerLayout = Instance.new("UIListLayout")
    ClearInnerLayout.FillDirection = Enum.FillDirection.Horizontal
    ClearInnerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    ClearInnerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    ClearInnerLayout.SortOrder = Enum.SortOrder.LayoutOrder
    ClearInnerLayout.Padding = UDim.new(0, 5)
    ClearInnerLayout.Parent = ClearInner

    local ClearIcon = MakeIcon(Library, ClearButton, "trash-2", 12, "FontColor")
    ClearIcon.Parent = ClearInner
    ClearIcon.LayoutOrder = 1

    local ClearLabel = MakeText(Library, ClearButton, "Clear", 10, true, 0.35)
    ClearLabel.Parent = ClearInner
    ClearLabel.LayoutOrder = 2
    ClearLabel.TextXAlignment = Enum.TextXAlignment.Left

    ClearButton.MouseEnter:Connect(function()
        SetIconColorScheme(Library, ClearIcon, "DestructiveColor")
        TweenService:Create(ClearButton, Library.TweenInfo, { BackgroundTransparency = 0.15 }):Play()
    end)
    ClearButton.MouseLeave:Connect(function()
        SetIconColorScheme(Library, ClearIcon, "FontColor")
        TweenService:Create(ClearButton, Library.TweenInfo, { BackgroundTransparency = 0.35 }):Play()
    end)

    local PlaylistSub = MakeText(Library, PlaylistCard, "Tap a song to play it", 10, false, 0.45)
    PlaylistSub.Position = UDim2.fromOffset(14, 32)
    PlaylistSub.Size = UDim2.new(1, -28, 0, 13)

    local SongList = Instance.new("ScrollingFrame")
    SongList.BackgroundTransparency = 1
    SongList.BorderSizePixel = 0
    SongList.Size = UDim2.new(1, -16, 1, -58)
    SongList.Position = UDim2.fromOffset(8, 50)
    SongList.CanvasSize = UDim2.fromOffset(0, 0)
    SongList.AutomaticCanvasSize = Enum.AutomaticSize.Y
    SongList.ScrollBarThickness = 2
    SongList.ScrollingDirection = Enum.ScrollingDirection.Y
    SongList.Parent = PlaylistCard

    Library:AddToRegistry(SongList, { ScrollBarImageColor3 = "OutlineColor" })
    SongList.ScrollBarImageColor3 = Library.Scheme.OutlineColor

    local SongListLayout = Instance.new("UIListLayout")
    SongListLayout.SortOrder = Enum.SortOrder.LayoutOrder
    SongListLayout.Padding = UDim.new(0, 4)
    SongListLayout.Parent = SongList

    local EmptyLabel = MakeText(Library, SongList, "No songs yet, drop .mp3 files into " .. MUSIC_FOLDER, 10, false, 0.25)
    EmptyLabel.Name = "EmptyState"
    EmptyLabel.Size = UDim2.new(1, 0, 0, 30)
    EmptyLabel.TextWrapped = true
    EmptyLabel.TextTruncate = Enum.TextTruncate.None
    EmptyLabel.TextXAlignment = Enum.TextXAlignment.Center
    EmptyLabel.LayoutOrder = 0

    --// Seek dragger (jump position inside the loaded song) \\--
    local SeekDragger = AddDragger({
        UpdateFromMouse = function()
            local Length = Sound.TimeLength
            if CurrentIndex == 0 or Length <= 0 or PlaybackState == "Stopped" then
                return
            end
            local Relative = math.clamp((Mouse.X - SeekBar.AbsolutePosition.X) / math.max(SeekBar.AbsoluteSize.X, 1), 0, 1)
            SeekFill.Size = UDim2.fromScale(Relative, 1)
            SeekKnob.Position = UDim2.new(Relative, 0, 0.5, 0)
            Sound.TimePosition = Relative * Length
        end,
    })

    SeekBar.InputBegan:Connect(function(Input)
        if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
            if CurrentIndex == 0 or Sound.TimeLength <= 0 or PlaybackState == "Stopped" then
                return
            end
            BeginDrag(SeekDragger)
        end
    end)

    --// Playback logic \\--
    local function RandomIndex(): number
        local Count = #Playlist
        if Count <= 1 then
            return Count == 1 and 1 or CurrentIndex
        end

        local Index = math.random(1, Count)
        if Index == CurrentIndex then
            Index = (Index % Count) + 1
        end
        return Index
    end

    UpdateNowPlaying = function()
        local Song = Playlist[CurrentIndex]
        if Song then
            SetText(SongLabel, Song.Name)
            SetText(SongDetail, Song.Detail)
        else
            SetText(SongLabel, "Nothing playing")
            SetText(SongDetail, "Add songs from the playlist card")
        end

        if PlaybackState == "Playing" then
            SetText(StatusLabel, "Playing")
            SetLabelScheme(Library, StatusLabel, "AccentColor")
            StatusLabel.TextTransparency = 0
        elseif PlaybackState == "Paused" then
            SetText(StatusLabel, "Paused")
            SetLabelScheme(Library, StatusLabel, "FontColor")
            StatusLabel.TextTransparency = 0.35
        else
            SetText(StatusLabel, "Stopped")
            SetLabelScheme(Library, StatusLabel, "FontColor")
            StatusLabel.TextTransparency = 0.45
        end

        PlayPauseIcon = SwapIcon(Library, PlayPauseIcon, PlaybackState == "Playing" and "pause" or "play", "WhiteColor")
    end

    StopSong = function()
        PlaybackState = "Stopped"
        Sound:Stop()
        SeekFill.Size = UDim2.fromScale(0, 1)
        SeekKnob.Position = UDim2.new(0, 0, 0.5, 0)
        SetText(TimeCurrent, "0:00")
        UpdateNowPlaying()
    end

    PlayIndex = function(Index: number)
        local Song = Playlist[Index]
        if not Song then
            return
        end

        SwitchingSongs = true
        CurrentIndex = Index
        PlaybackState = "Playing"

        Sound:Stop()
        Sound.SoundId = Song.SoundId
        Sound.Volume = Volume / 100
        Sound.PlaybackSpeed = Speed
        Sound.TimePosition = 0
        Sound:Play()

        task.delay(0.3, function()
            SwitchingSongs = false
        end)

        --// Detect unloadable songs (bad asset id / missing file) and skip them \\--
        task.spawn(function()
            pcall(function()
                ContentProvider:PreloadAsync({ Sound })
            end)
            task.wait(0.25)

            if Sound.SoundId ~= Song.SoundId or CurrentIndex ~= Index or not Page.Parent then
                return
            end

            if Sound.IsLoaded or Sound.TimeLength > 0 then
                ConsecutiveFailures = 0
                return
            end

            if PlaybackState ~= "Playing" then
                return
            end

            ConsecutiveFailures += 1
            if ConsecutiveFailures >= 3 then
                Notify("Music Player", "Failed to load 3 songs in a row, playback stopped.")
                StopSong()
            else
                Notify("Music Player", ('Could not load "%s", skipping.'):format(Song.Name))
                NextSong()
            end
        end)

        UpdateNowPlaying()
        RefreshPlaylist()
    end

    AutoAdvance = function()
        if SwitchingSongs or PlaybackState ~= "Playing" then
            return
        end
        if os.clock() - LastAdvanceAt < 0.5 then
            return
        end
        LastAdvanceAt = os.clock()

        if Shuffle then
            PlayIndex(RandomIndex())
        elseif CurrentIndex < #Playlist then
            PlayIndex(CurrentIndex + 1)
        elseif LoopPlaylist then
            PlayIndex(1)
        else
            StopSong()
        end
    end

    table.insert(Connections, Sound.Ended:Connect(function()
        AutoAdvance()
    end))

    NextSong = function()
        if #Playlist == 0 then
            Notify("Music Player", "The playlist is empty.")
            return
        end

        if Shuffle then
            PlayIndex(RandomIndex())
        elseif CurrentIndex < #Playlist then
            PlayIndex(CurrentIndex + 1)
        else
            PlayIndex(1)
        end
    end

    PrevSong = function()
        if #Playlist == 0 then
            Notify("Music Player", "The playlist is empty.")
            return
        end

        if Shuffle then
            PlayIndex(RandomIndex())
        elseif CurrentIndex > 1 then
            PlayIndex(CurrentIndex - 1)
        elseif LoopPlaylist then
            PlayIndex(#Playlist)
        else
            PlayIndex(1)
        end
    end

    TogglePlay = function()
        if PlaybackState == "Playing" then
            PlaybackState = "Paused"
            Sound:Pause()
            UpdateNowPlaying()
        elseif PlaybackState == "Paused" then
            local Length = Sound.TimeLength
            if Length > 0 and Sound.TimePosition >= Length - 0.1 then
                Sound.TimePosition = 0
            end
            PlaybackState = "Playing"
            Sound:Resume()
            UpdateNowPlaying()
        elseif CurrentIndex > 0 and Playlist[CurrentIndex] then
            PlayIndex(CurrentIndex)
        elseif #Playlist > 0 then
            PlayIndex(Shuffle and RandomIndex() or 1)
        else
            Notify("Music Player", "The playlist is empty.")
        end
    end

    RemoveSong = function(Index: number)
        local Song = Playlist[Index]
        if not Song then
            return
        end

        local WasCurrent = Index == CurrentIndex
        local WasPlaying = PlaybackState == "Playing"
        table.remove(Playlist, Index)

        if WasCurrent then
            if #Playlist == 0 then
                CurrentIndex = 0
                StopSong()
            elseif WasPlaying then
                PlayIndex(math.clamp(Index, 1, #Playlist))
            else
                CurrentIndex = 0
                StopSong()
            end
        elseif Index < CurrentIndex then
            CurrentIndex -= 1
        end

        RefreshPlaylist()
        Notify("Music Player", "Removed " .. tostring(Song.Name) .. ".")
    end

    RefreshPlaylist = function()
        SetText(CountLabel, #Playlist == 1 and "1 song" or (#Playlist .. " songs"))
        EmptyLabel.Visible = #Playlist == 0

        for _, Child in SongList:GetChildren() do
            if Child.Name == "SongRow" then
                Child:Destroy()
            end
        end

        for Index, Song in Playlist do
            local IsCurrent = Index == CurrentIndex

            local Row = Instance.new("TextButton")
            Row.Name = "SongRow"
            Row.BackgroundColor3 = Library.Scheme.BackgroundColor
            Row.BackgroundTransparency = IsCurrent and 0 or 0.35
            Row.BorderSizePixel = 0
            Row.AutoButtonColor = false
            Row.Text = ""
            Row.Size = UDim2.new(1, 0, 0, 30)
            Row.LayoutOrder = Index
            Row.Parent = SongList

            Library:AddToRegistry(Row, { BackgroundColor3 = "BackgroundColor" })
            MakeCorner(Library, Row, 4)

            local Indicator = MakeIcon(Library, Row, "music", 13, IsCurrent and "AccentColor" or "FontColor")
            Indicator.Position = UDim2.fromOffset(8, 8)

            if not IsCurrent then
                if Indicator:IsA("TextLabel") or Indicator:IsA("TextButton") then
                    Indicator.TextTransparency = 0.5
                else
                    Indicator.ImageTransparency = 0.5
                end
            end

            local NameLabel = MakeText(
                Library,
                Row,
                Index .. ". " .. tostring(Song.Name),
                11,
                IsCurrent,
                IsCurrent and 0 or 0.3
            )
            NameLabel.Position = UDim2.fromOffset(28, 8)
            NameLabel.Size = UDim2.new(1, -110, 0, 14)

            local Badge = Instance.new("Frame")
            Badge.BackgroundColor3 = Library.Scheme.AccentColor
            Badge.BackgroundTransparency = 0.82
            Badge.BorderSizePixel = 0
            Badge.AnchorPoint = Vector2.new(1, 0.5)
            Badge.Position = UDim2.new(1, -36, 0.5, 0)
            Badge.Size = UDim2.fromOffset(32, 16)
            Badge.Parent = Row

            Library:AddToRegistry(Badge, { BackgroundColor3 = "AccentColor" })
            MakeCorner(Library, Badge, 4)

            local BadgeLabel = Instance.new("TextLabel")
            BadgeLabel.BackgroundTransparency = 1
            BadgeLabel.Size = UDim2.fromScale(1, 1)
            BadgeLabel.Text = tostring(Song.Badge)
            BadgeLabel.TextSize = 9
            BadgeLabel.TextXAlignment = Enum.TextXAlignment.Center
            BadgeLabel.TextYAlignment = Enum.TextYAlignment.Center
            BadgeLabel.Parent = Badge

            Library:AddToRegistry(BadgeLabel, { TextColor3 = "AccentColor", FontFace = "Font" })
            BadgeLabel.TextColor3 = Library.Scheme.AccentColor
            BadgeLabel.FontFace = Library.Scheme.Font

            local Remove = Instance.new("TextButton")
            Remove.BackgroundColor3 = Library.Scheme.DestructiveColor
            Remove.BackgroundTransparency = 1
            Remove.BorderSizePixel = 0
            Remove.AutoButtonColor = false
            Remove.Text = ""
            Remove.AnchorPoint = Vector2.new(1, 0.5)
            Remove.Position = UDim2.new(1, -6, 0.5, 0)
            Remove.Size = UDim2.fromOffset(24, 24)
            Remove.Parent = Row

            Library:AddToRegistry(Remove, { BackgroundColor3 = "DestructiveColor" })
            MakeCorner(Library, Remove, 4)

            local RemoveIcon = MakeIcon(Library, Remove, "x", 12, "FontColor")
            RemoveIcon.AnchorPoint = Vector2.new(0.5, 0.5)
            RemoveIcon.Position = UDim2.fromScale(0.5, 0.5)

            Row.MouseEnter:Connect(function()
                TweenService:Create(Row, Library.TweenInfo, { BackgroundTransparency = IsCurrent and 0 or 0.15 }):Play()
            end)
            Row.MouseLeave:Connect(function()
                TweenService:Create(Row, Library.TweenInfo, { BackgroundTransparency = IsCurrent and 0 or 0.35 }):Play()
            end)
            Row.MouseButton1Click:Connect(function()
                if Index == CurrentIndex then
                    TogglePlay()
                else
                    PlayIndex(Index)
                end
            end)

            Remove.MouseEnter:Connect(function()
                SetIconColorScheme(Library, RemoveIcon, "DestructiveColor")
                TweenService:Create(Remove, Library.TweenInfo, { BackgroundTransparency = 0.85 }):Play()
            end)
            Remove.MouseLeave:Connect(function()
                SetIconColorScheme(Library, RemoveIcon, "FontColor")
                TweenService:Create(Remove, Library.TweenInfo, { BackgroundTransparency = 1 }):Play()
            end)
            Remove.MouseButton1Click:Connect(function()
                RemoveSong(Index)
            end)
        end
    end

    local function ClearPlaylist()
        if #Playlist == 0 then
            Notify("Music Player", "The playlist is already empty.")
            return
        end

        table.clear(Playlist)
        CurrentIndex = 0
        StopSong()
        RefreshPlaylist()
        Notify("Music Player", "Playlist cleared.")
    end

    --// Resolves a .mp3 from FALLENS/music into a playable rbxasset uri \\--
    local function AddFileSong(FileName: any, Name: any, Silent: boolean?): boolean
        local Clean = Trim(tostring(FileName))
        if Clean == "" then
            if not Silent then
                Notify("Music Player", "Enter a file name like song.mp3 first.")
            end
            return false
        end

        local Resolver = (typeof(getcustomasset) == "function" and getcustomasset)
            or (typeof(getsynasset) == "function" and getsynasset)
        if not Resolver then
            if not Silent then
                Notify("Music Player", "This executor cannot load local files (getcustomasset is missing).")
            end
            return false
        end

        --// Accepts bare names as well as full FALLENS/music/... spellings, the legacy
        --// workspace/FALLENS/music and workspace.FALLENS.music prefixes are stripped too \\--
        local Relative = Clean:gsub("\\", "/")
        for _, Prefix in { "FALLENS/music/", "workspace/FALLENS/music/", "workspace.FALLENS.music/" } do
            if Relative:sub(1, #Prefix):lower() == Prefix:lower() then
                Relative = Relative:sub(#Prefix + 1)
                break
            end
        end

        if Relative == "" then
            if not Silent then
                Notify("Music Player", "Enter a file name like song.mp3 first.")
            end
            return false
        end

        --// The music folder is checked first, then the legacy spellings, then the root \\--
        local Loaded, Uri = nil, nil
        for _, Candidate in {
            MUSIC_FOLDER .. "/" .. Relative,
            "workspace/FALLENS/music/" .. Relative,
            "workspace.FALLENS.music/" .. Relative,
            Relative,
        } do
            local Ok, Result = pcall(Resolver, Candidate)
            if Ok and typeof(Result) == "string" and Result ~= "" then
                Loaded, Uri = Candidate, Result
                break
            end
        end

        if not Uri then
            if not Silent then
                Notify(
                    "Music Player",
                    ('Could not load "%s", place the .mp3 inside %s.'):format(Relative, MUSIC_FOLDER)
                )
            end
            return false
        end

        local Label = (Name ~= nil and Trim(tostring(Name)) ~= "") and Trim(tostring(Name))
            or (Relative:gsub("%.[^%.]+$", "") or Relative)

        local Ext = Relative:lower():match("%.([%w]+)$")
        table.insert(Playlist, {
            Name = Label,
            Badge = (Ext and Ext:upper()) or "MP3",
            Detail = "Local file - " .. Loaded,
            SoundId = Uri,
            File = Relative,
        })
        return true
    end

    local function AddAssetSong(Source: any, Name: any): boolean
        local Id = tostring(Source):match("%d+")
        if not Id then
            Notify("Music Player", "That does not look like a valid asset ID.")
            return false
        end

        local Label = (Name ~= nil and Trim(tostring(Name)) ~= "") and Trim(tostring(Name)) or ("Asset " .. Id)

        table.insert(Playlist, {
            Name = Label,
            Badge = "ID",
            Detail = "Roblox asset - rbxassetid://" .. Id,
            SoundId = "rbxassetid://" .. Id,
        })
        return true
    end

    --// Auto scan: lists every .mp3 / .ogg inside FALLENS/music \\--
    local function ListAudioFiles(): { string }
        local Found: { string } = {}
        if typeof(listfiles) ~= "function" then
            return Found
        end

        --// Bare names are only trusted when we listed the music folder ourselves, entries
        --// coming from a plain workspace listing must contain the music folder marker \\--
        local function Collect(Entries: { any }, Direct: boolean, Prefix: string, Depth: number, Root: string)
            for _, RawPath in Entries do
                local Path = tostring(RawPath):gsub("\\", "/")
                if Path ~= "" then
                    local Relative = ToMusicRelative(Path)
                    if Relative == nil and (Direct or Prefix ~= "") then
                        Relative = Prefix == "" and Path or (Prefix .. "/" .. Path)
                    end

                    if Relative ~= nil then
                        if IsAudioFile(Relative) then
                            table.insert(Found, Relative)
                        elseif Depth == 0 and not Relative:match("%.[^%.]+$") then
                            --// A subfolder of the music folder, scan one level deeper. The folder it
                            --// was listed from is tried first (so legacy alias subfolders work), then
                            --// the full entry path, then the new music folder \\--
                            local SubOk, SubEntries = pcall(listfiles, Root .. "/" .. Relative)
                            if not (SubOk and typeof(SubEntries) == "table") and Path ~= Relative then
                                SubOk, SubEntries = pcall(listfiles, Path)
                            end
                            if not (SubOk and typeof(SubEntries) == "table") and Root ~= MUSIC_FOLDER then
                                SubOk, SubEntries = pcall(listfiles, MUSIC_FOLDER .. "/" .. Relative)
                            end
                            if SubOk and typeof(SubEntries) == "table" then
                                Collect(SubEntries, false, Relative, Depth + 1, Root)
                            end
                        end
                    end
                end
            end
        end

        --// Prefer listing the music folder itself, then the legacy aliases, then the root \\--
        local Ok, Entries = pcall(listfiles, MUSIC_FOLDER)
        if Ok and typeof(Entries) == "table" then
            Collect(Entries, true, "", 0, MUSIC_FOLDER)
        end

        for _, Alias in MUSIC_FOLDER_ALIASES do
            local AliasOk, AliasEntries = pcall(listfiles, Alias)
            if AliasOk and typeof(AliasEntries) == "table" then
                Collect(AliasEntries, true, "", 0, Alias)
            end
        end

        local RootOk, RootEntries = pcall(listfiles)
        if RootOk and typeof(RootEntries) == "table" then
            Collect(RootEntries, false, "", 0, MUSIC_FOLDER)
        end

        --// Dedupe + sort case-insensitively so no song is ever listed twice \\--
        local Seen: { [string]: boolean } = {}
        local Unique: { string } = {}
        for _, Name in Found do
            local Key = Name:lower()
            if not Seen[Key] then
                Seen[Key] = true
                table.insert(Unique, Name)
            end
        end

        table.sort(Unique, function(A, B)
            return A:lower() < B:lower()
        end)
        return Unique
    end

    local function HasFileSong(FileName: string): boolean
        local Lower = tostring(FileName):lower()
        for _, Song in Playlist do
            if Song.File and tostring(Song.File):lower() == Lower then
                return true
            end
        end
        return false
    end

    --// Adds every not-yet-listed audio file, returns how many were added \\--
    local function ScanLocalFiles(Silent: boolean?): number
        if not Page.Parent then
            return 0
        end

        --// The music folder is (re)created so there is always a place to drop songs \\--
        EnsureMusicFolder()

        local Files = ListAudioFiles()
        if #Files == 0 then
            if not Silent then
                Notify(
                    "Music Player",
                    ("No .mp3 files in %s yet, drop your songs inside that folder."):format(MUSIC_FOLDER)
                )
            end
            return 0
        end

        local Added = 0
        for _, Name in Files do
            if not HasFileSong(Name) and AddFileSong(Name, nil, true) then
                Added += 1
            end
        end

        if Added > 0 then
            RefreshPlaylist()
            Notify("Music Player", ("Auto-added %d song(s) from your music folder."):format(Added))
        elseif not Silent then
            Notify("Music Player", "No new .mp3 files to add.")
        end
        return Added
    end

    local function AddFromInput(Mode: string)
        local Source = Trim(tostring(SourceBox.Text))
        local Name = Trim(tostring(NameBox.Text))

        if Source == "" then
            Notify("Music Player", "Enter an asset ID or an .mp3 file name first.")
            return
        end

        local Added = false
        if Mode == "Asset" then
            Added = AddAssetSong(Source, Name)
        else
            Added = AddFileSong(Source, Name)
        end

        if Added then
            NameBox.Text = ""
            SourceBox.Text = ""
            RefreshPlaylist()

            --// The very first song starts playing right away \\--
            if PlaybackState == "Stopped" and CurrentIndex == 0 then
                PlayIndex(#Playlist)
            end
        end
    end

    --// Per-frame repaint for the seek bar & auto advance fallback \\--
    local function UpdateMusic()
        local Length = Sound.TimeLength
        local Position = Sound.TimePosition

        if PlaybackState ~= "Stopped" and Length > 0 and not SeekDragger.Dragging then
            local Alpha = math.clamp(Position / Length, 0, 1)
            SeekFill.Size = UDim2.fromScale(Alpha, 1)
            SeekKnob.Position = UDim2.new(Alpha, 0, 0.5, 0)
        end

        SetText(TimeCurrent, FormatMusicTime(Position))
        SetText(TimeTotal, Length > 0 and FormatMusicTime(Length) or "--:--")

        if PlaybackState == "Playing" and Length > 0 and Position > 0 and Position >= Length - 0.06 then
            AutoAdvance()
        end
    end

    --// Button wiring \\--
    PrevButton.MouseButton1Click:Connect(PrevSong)
    PlayPauseButton.MouseButton1Click:Connect(TogglePlay)
    StopButton.MouseButton1Click:Connect(StopSong)
    NextButton.MouseButton1Click:Connect(NextSong)

    local function SetLoop(Enabled: boolean)
        LoopPlaylist = Enabled
        SetModeVisual(LoopButton, LoopIcon, LoopLabel, LoopState, LoopDot, Enabled)
    end

    local function SetShuffle(Enabled: boolean)
        Shuffle = Enabled
        SetModeVisual(ShuffleButton, ShuffleIcon, ShuffleLabel, ShuffleState, ShuffleDot, Enabled)
    end

    LoopButton.MouseButton1Click:Connect(function()
        SetLoop(not LoopPlaylist)
    end)
    ShuffleButton.MouseButton1Click:Connect(function()
        SetShuffle(not Shuffle)
    end)

    AddAssetButton.MouseButton1Click:Connect(function()
        AddFromInput("Asset")
    end)
    AddFileButton.MouseButton1Click:Connect(function()
        AddFromInput("File")
    end)
    RescanButton.MouseButton1Click:Connect(function()
        ScanLocalFiles(false)
    end)
    ClearButton.MouseButton1Click:Connect(ClearPlaylist)

    SourceBox.FocusLost:Connect(function(EnterPressed)
        if not EnterPressed then
            return
        end

        local Text = Trim(tostring(SourceBox.Text))
        if Text == "" then
            return
        end

        --// Enter smart-detects asset ids vs file names \\--
        if Text:match("^%d+$") or Text:match("^rbxassetid://%d+$") then
            AddFromInput("Asset")
        else
            AddFromInput("File")
        end
    end)

    local function DestroyMusic()
        for _, Connection in Connections do
            pcall(function()
                Connection:Disconnect()
            end)
        end
        table.clear(Connections)
        table.clear(Draggers)

        pcall(function()
            Sound:Stop()
        end)
        Sound:Destroy()
    end

    RefreshPlaylist()
    UpdateNowPlaying()

    --// Auto add: create FALLENS/music and load every song inside it \\--
    task.spawn(function()
        local Created = EnsureMusicFolder()
        local Added = ScanLocalFiles(true)

        --// Fresh install: point the user at the folder that was just made for them \\--
        if Created and Added == 0 then
            Notify("Music Player", ("Music folder ready: %s. Drop your .mp3 files inside it."):format(MUSIC_FOLDER))
        end
    end)

    --// Music player API (also exposed through Dashboard.Music) \\--
    return {
        Update = UpdateMusic,
        Destroy = DestroyMusic,

        Play = function()
            if PlaybackState ~= "Playing" then
                TogglePlay()
            end
        end,
        Pause = function()
            if PlaybackState == "Playing" then
                TogglePlay()
            end
        end,
        Toggle = TogglePlay,
        Stop = StopSong,
        Next = NextSong,
        Previous = PrevSong,

        AddAsset = AddAssetSong,
        AddFile = AddFileSong,
        Remove = RemoveSong,
        Clear = ClearPlaylist,
        Scan = ScanLocalFiles,
        GetPlaylist = function()
            return Playlist
        end,

        SetLoop = SetLoop,
        SetShuffle = SetShuffle,
        SetVolume = function(Value: number)
            VolumeSlider.SetValue(Value)
        end,
        SetSpeed = function(Value: number)
            SpeedSlider.SetValue(Value)
        end,
        IsPlaying = function()
            return PlaybackState == "Playing"
        end,
    }
end

--// Dashboard creation \\--
function DashboardManager:CreateDashboard(Tab: any, Config: any)
    local Library = DashboardManager.Library
    assert(Library, "Library is not set, call DashboardManager:SetLibrary(Library) first.")
    assert(typeof(Tab) == "table" and Tab.Container, "Expected a valid Tab for the dashboard.")

    Config = Library:Validate(Config or {}, Defaults)

    --// Small notify wrapper so the new server / privacy features stay tidy \\--
    local function NotifyCard(Title: string, Description: string, Time: number?)
        if Library and Library.Notify then
            Library:Notify({
                Title = Title,
                Description = Description,
                Time = Time or 4,
            })
        end
    end

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

    --// Identity privacy (hide username & display name): masks the profile texts and the
    --// name above your own character for the local view only \\--
    local IdentityHidden = false
    local IdentityMask = "*******"
    local SavedDisplayDistance: any = nil
    local CharacterWatchConnection: any = nil

    local function RefreshIdentityTexts()
        local DisplayNameText = tostring(LocalPlayer.DisplayName)
        local AccountNameText = tostring(LocalPlayer.Name)

        if IdentityHidden then
            DisplayNameText = IdentityMask
            AccountNameText = IdentityMask
        end

        SetText(Welcome, "Hello, " .. DisplayNameText)
        SetText(Username, GetGreeting(Config.Greetings) .. " | @" .. AccountNameText)
    end

    local function ApplyCharacterPrivacy(Character: any)
        if not IdentityHidden then
            return
        end

        task.spawn(function()
            pcall(function()
                local Humanoid = Character:WaitForChild("Humanoid", 10)
                if Humanoid and IdentityHidden then
                    if SavedDisplayDistance == nil then
                        SavedDisplayDistance = Humanoid.DisplayDistanceType
                    end
                    Humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
                end
            end)
        end)
    end

    local function SetIdentityHidden(Hidden: boolean, Silent: boolean?)
        IdentityHidden = Hidden
        RefreshIdentityTexts()

        if Hidden then
            if LocalPlayer.Character then
                ApplyCharacterPrivacy(LocalPlayer.Character)
            end

            if not CharacterWatchConnection then
                CharacterWatchConnection = LocalPlayer.CharacterAdded:Connect(ApplyCharacterPrivacy)
            end

            if not Silent then
                NotifyCard("Privacy", "Username & display name are hidden locally.")
            end
        else
            if CharacterWatchConnection then
                CharacterWatchConnection:Disconnect()
                CharacterWatchConnection = nil
            end

            pcall(function()
                local Humanoid = LocalPlayer.Character
                    and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
                if Humanoid then
                    Humanoid.DisplayDistanceType = SavedDisplayDistance
                        or Enum.HumanoidDisplayDistanceType.Viewer
                end
            end)
            SavedDisplayDistance = nil

            if not Silent then
                NotifyCard("Privacy", "Username & display name are visible again.")
            end
        end
    end

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

    local function SelectPage(PageName: string)
        ActivePage = PageName

        for Name, Page in Pages do
            Page.Visible = Name == PageName
        end

        for Name, Button in SegmentButtons do
            local IsActive = Name == PageName

            Button.Root.BackgroundTransparency = IsActive and 0.05 or 0.55
            SetIconColorScheme(Library, Button.Icon, IsActive and "AccentColor" or "FontColor")
            Button.Label.TextTransparency = IsActive and 0 or 0.25
        end
    end

    local VisibleSegmentCount = 0
    local CustomSegments = {}

    local SegmentConfig = typeof(Config.Segments) == "table" and Config.Segments or {}
    for Key, SegmentData in SegmentConfig do
        if
            Key ~= "Details"
            and Key ~= "Music"
            and Key ~= 1
            and typeof(Key) == "string"
            and typeof(SegmentData) == "table"
        then
            table.insert(CustomSegments, { Key = Key, Data = SegmentData })
        end
    end

    --// Script & UI segments go first like the modern UI default, the rest alphabetically \\--
    local DefaultSegmentOrder = { Script = 100, UI = 200, Ui = 200 }
    table.sort(CustomSegments, function(A, B)
        local OrderA = tonumber(A.Data.Order) or DefaultSegmentOrder[A.Key] or 1000
        local OrderB = tonumber(B.Data.Order) or DefaultSegmentOrder[B.Key] or 1000

        if OrderA ~= OrderB then
            return OrderA < OrderB
        end

        return A.Key < B.Key
    end)

    local ShownCustomSegments = {}
    for _, Entry in CustomSegments do
        if Entry.Data.Show ~= false then
            table.insert(ShownCustomSegments, Entry)
        end
    end

    local ShowDetailsSegment = Config.ShowDetailsSegment ~= false
    local ShowMusicSegment = Config.ShowMusicSegment ~= false
    if ShowMusicSegment and typeof(SegmentConfig.Music) == "table" and SegmentConfig.Music.Show == false then
        ShowMusicSegment = false
    end

    VisibleSegmentCount = (ShowDetailsSegment and 1 or 0) + (ShowMusicSegment and 1 or 0) + #ShownCustomSegments

    if VisibleSegmentCount <= 0 then
        ShowDetailsSegment = true
        VisibleSegmentCount = 1
    end

    --// Pages + segment buttons \\--
    local CardGap = 10
    --// tallest columns: left = server (job id + hop + join rows) + discord cards,
    --// right = executor + friends + privacy cards
    local ContentHeight = 296 + CardGap + 112
    ContentHeight = math.max(ContentHeight, 104 + CardGap + 154 + CardGap + 154)
    if ShowMusicSegment then
        --// music page: now playing (178) + audio (122) / add music (126) + playlist (174) cards
        ContentHeight = math.max(ContentHeight, 178 + CardGap + 122)
    end

    local ContentHolder = Instance.new("Frame")
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
    local PrivacyLabels = {}

    --// Server hop: pulls the public server list and teleports into another instance.
    --// Smallest = true targets the least populated server instead of a random one \\--
    local HopBusy = false
    local function HopServer(Smallest: boolean)
        if HopBusy then
            return
        end
        HopBusy = true

        task.spawn(function()
            local Servers = FetchPublicServers(Smallest and 3 or 2)
            if #Servers == 0 then
                NotifyCard("Server Hop", "No other joinable public servers were found for this game.")
                HopBusy = false
                return
            end

            if Smallest then
                table.sort(Servers, function(A, B)
                    return (tonumber(A.playing) or 0) < (tonumber(B.playing) or 0)
                end)
            else
                for Index = #Servers, 2, -1 do
                    local SwapIndex = math.random(Index)
                    Servers[Index], Servers[SwapIndex] = Servers[SwapIndex], Servers[Index]
                end
            end

            --// A few candidates are tried in order in case a teleport call is rejected \\--
            local LastError = "unknown error"
            for Attempt = 1, math.min(#Servers, 4) do
                local Target = Servers[Attempt]
                local Ok, Err = TeleportToJobId(Target.id)
                if Ok then
                    local PlayerCount = tonumber(Target.playing) or 0
                    local Message = Smallest
                        and ("Joining the smallest server (%d players)."):format(PlayerCount)
                        or ("Joining a server with %d players."):format(PlayerCount)
                    NotifyCard("Teleporting", Message, 5)

                    task.delay(8, function()
                        HopBusy = false
                    end)
                    return
                end
                LastError = Err
            end

            NotifyCard("Server Hop", "Teleport failed: " .. LastError, 6)
            HopBusy = false
        end)
    end

    do
        --// Server card: live stats, a tap-to-copy job id, server hop / small server
        --// buttons and the join-by-job-id row \\--
        local ServerCard = MakePanel(Library, LeftColumn, UDim2.new(1, 0, 0, 296))
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

        --// Job id row: styled like a stat box, tap to copy the current server's job id \\--
        local CurrentJobId = GetCurrentJobId()

        local JobIdButton = Instance.new("TextButton")
        JobIdButton.BackgroundColor3 = Library.Scheme.BackgroundColor
        JobIdButton.BackgroundTransparency = 0.25
        JobIdButton.BorderSizePixel = 0
        JobIdButton.AutoButtonColor = false
        JobIdButton.Text = ""
        JobIdButton.Size = UDim2.new(1, -6, 0, 42)
        JobIdButton.Position = UDim2.new(0, 3, 0, 150)
        JobIdButton.ClipsDescendants = true
        JobIdButton.Parent = ServerCard

        Library:AddToRegistry(JobIdButton, { BackgroundColor3 = "BackgroundColor" })
        MakeCorner(Library, JobIdButton, 4)

        local JobIdTitle = MakeText(Library, JobIdButton, "Job ID (tap to copy)", 10, true, 0.13)
        JobIdTitle.Position = UDim2.fromOffset(10, 7)
        JobIdTitle.Size = UDim2.new(1, -34, 0, 13)

        local JobIdValue = MakeText(Library, JobIdButton, CurrentJobId ~= "" and CurrentJobId or "N/A", 10, false, 0.35)
        JobIdValue.Position = UDim2.fromOffset(10, 21)
        JobIdValue.Size = UDim2.new(1, -34, 0, 13)

        local JobIdCopyIcon = MakeIcon(Library, JobIdButton, "copy", 13, "AccentColor")
        JobIdCopyIcon.AnchorPoint = Vector2.new(1, 0.5)
        JobIdCopyIcon.Position = UDim2.new(1, -10, 0.5, 0)

        JobIdButton.MouseEnter:Connect(function()
            TweenService:Create(JobIdButton, Library.TweenInfo, { BackgroundTransparency = 0.1 }):Play()
        end)
        JobIdButton.MouseLeave:Connect(function()
            TweenService:Create(JobIdButton, Library.TweenInfo, { BackgroundTransparency = 0.25 }):Play()
        end)

        JobIdButton.MouseButton1Click:Connect(function()
            if CurrentJobId == "" then
                NotifyCard("Job ID", "This session has no Job ID (Roblox Studio or a local server).")
                return
            end

            if CopyToClipboard(CurrentJobId) then
                NotifyCard("Copied Job ID", CurrentJobId, 6)
            else
                NotifyCard("Job ID", "Your executor does not expose a clipboard function.")
            end
        end)

        --// Server hop + small server buttons \\--
        local HopButton = MakeActionButton(Library, ServerCard, "Server Hop", "shuffle", 0, 196, 0.5)
        local SmallButton = MakeActionButton(Library, ServerCard, "Small Server", "users", 0.5, 196, 0.5)

        HopButton.MouseButton1Click:Connect(function()
            HopServer(false)
        end)
        SmallButton.MouseButton1Click:Connect(function()
            HopServer(true)
        end)

        --// Join server by job id: input box + join button \\--
        local JoinBox = Instance.new("TextBox")
        JoinBox.BackgroundColor3 = Library.Scheme.BackgroundColor
        JoinBox.BackgroundTransparency = 0.25
        JoinBox.BorderSizePixel = 0
        JoinBox.Size = UDim2.new(0.55, -6, 0, 42)
        JoinBox.Position = UDim2.new(0, 3, 0, 242)
        JoinBox.Text = ""
        JoinBox.PlaceholderText = "Paste Job ID or link"
        JoinBox.TextSize = 10
        JoinBox.TextXAlignment = Enum.TextXAlignment.Left
        JoinBox.ClearTextOnFocus = false
        JoinBox.ClipsDescendants = true
        JoinBox.Parent = ServerCard

        Library:AddToRegistry(JoinBox, { TextColor3 = "FontColor", FontFace = "Font" })
        JoinBox.TextColor3 = Library.Scheme.FontColor
        JoinBox.FontFace = Library.Scheme.Font
        MakeCorner(Library, JoinBox, 4)

        local JoinStroke = MakeStroke(Library, JoinBox)

        local JoinPadding = Instance.new("UIPadding")
        JoinPadding.PaddingLeft = UDim.new(0, 10)
        JoinPadding.PaddingRight = UDim.new(0, 10)
        JoinPadding.Parent = JoinBox

        local JoinButton = MakeActionButton(Library, ServerCard, "Join Server", "log-in", 0.55, 242, 0.45)

        local JoinBusy = false
        local function DoJoinServer()
            if JoinBusy then
                return
            end

            local JobId = ExtractJobId(JoinBox.Text)
            if not JobId then
                NotifyCard("Join Server", "Paste a Job ID or a roblox.com server link first.")
                return
            end

            JoinBusy = true
            local Ok, Err = TeleportToJobId(JobId)
            if Ok then
                NotifyCard("Teleporting", "Joining server " .. JobId, 5)

                task.delay(8, function()
                    JoinBusy = false
                end)
            else
                NotifyCard("Join Server", "Teleport failed: " .. Err, 6)
                JoinBusy = false
            end
        end

        JoinButton.MouseButton1Click:Connect(DoJoinServer)
        JoinBox.Focused:Connect(function()
            JoinStroke.Color = Library.Scheme.AccentColor
            if Library.Registry[JoinStroke] then
                Library.Registry[JoinStroke].Color = "AccentColor"
            end
        end)
        JoinBox.FocusLost:Connect(function(EnterPressed: boolean)
            JoinStroke.Color = Library.Scheme.OutlineColor
            if Library.Registry[JoinStroke] then
                Library.Registry[JoinStroke].Color = "OutlineColor"
            end
            if EnterPressed then
                DoJoinServer()
            end
        end)
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
            CopyToClipboard(Link)

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

    do
        --// Privacy card (hide username & display name) \\--
        local PrivacyCard = MakePanel(Library, RightColumn, UDim2.new(1, 0, 0, 154))
        PrivacyCard.LayoutOrder = 3

        local PrivacyTitle = MakeText(Library, PrivacyCard, "Privacy", 16, true, 0)
        PrivacyTitle.Position = UDim2.fromOffset(14, 12)
        PrivacyTitle.Size = UDim2.new(1, -28, 0, 20)

        local PrivacySub =
            MakeText(Library, PrivacyCard, "Hide username & display name locally", 10, false, 0.45)
        PrivacySub.Position = UDim2.fromOffset(14, 32)
        PrivacySub.Size = UDim2.new(1, -28, 0, 14)

        local HideButton, HideIcon, HideLabel = MakeActionButton(
            Library,
            PrivacyCard,
            "Hide Username & Name",
            "eye-off",
            0,
            58,
            1,
            function()
                return IdentityHidden
            end
        )

        --// Status dot on the right edge of the toggle: dim while visible, lit while hidden \\--
        local HideDot = Instance.new("Frame")
        HideDot.BackgroundColor3 = Library.Scheme.OutlineColor
        HideDot.BorderSizePixel = 0
        HideDot.AnchorPoint = Vector2.new(1, 0.5)
        HideDot.Position = UDim2.new(1, -9, 0.5, 0)
        HideDot.Size = UDim2.fromOffset(5, 5)
        HideDot.Parent = HideButton

        Library:AddToRegistry(HideDot, { BackgroundColor3 = "OutlineColor" })
        local HideDotCorner = Instance.new("UICorner")
        HideDotCorner.CornerRadius = UDim.new(1, 0)
        HideDotCorner.Parent = HideDot

        PrivacyLabels.Status = MakeStat(Library, PrivacyCard, "Identity", "Visible", 0, 104, 1)

        local function SetPrivacyVisual(Hidden: boolean)
            HideButton.BackgroundColor3 = Hidden and Library.Scheme.AccentColor
                or Library.Scheme.BackgroundColor
            HideButton.BackgroundTransparency = Hidden and 0.1 or 0.25

            if Library.Registry[HideButton] then
                Library.Registry[HideButton].BackgroundColor3 = Hidden and "AccentColor" or "BackgroundColor"
            end

            SetIconColorScheme(Library, HideIcon, Hidden and "WhiteColor" or "AccentColor")
            SetLabelScheme(Library, HideLabel, Hidden and "WhiteColor" or "FontColor")
            HideLabel.TextTransparency = Hidden and 0 or 0.25

            HideDot.BackgroundColor3 = Hidden and Library.Scheme.WhiteColor or Library.Scheme.OutlineColor
            if Library.Registry[HideDot] then
                Library.Registry[HideDot].BackgroundColor3 = Hidden and "WhiteColor" or "OutlineColor"
            end

            SetText(PrivacyLabels.Status, Hidden and "Hidden" or "Visible")
        end

        HideButton.MouseButton1Click:Connect(function()
            SetIdentityHidden(not IdentityHidden)
            SetPrivacyVisual(IdentityHidden)
        end)
    end

    --// Custom segment pages (mirroring the modern UI segments: Script, UI, Changelog, ...) \\--
    if ShowDetailsSegment then
        local DetailsSegment = SegmentConfig.Details or SegmentConfig[1] or {}
        MakeSegment(
            "Details",
            DetailsSegment.Text or DetailsSegment.Name or Config.DetailsText,
            DetailsSegment.Icon or Config.DetailsIcon
        )
    end

    --// Music player segment, styled like the details & info page \\--
    local MusicPlayer = nil
    if ShowMusicSegment then
        local MusicSegment = SegmentConfig.Music or {}
        local MusicPage = CreateContentPage()
        Pages.Music = MusicPage

        MusicPlayer = CreateMusicPlayer(Library, MusicPage, {
            Volume = Config.MusicVolume,
            Speed = Config.MusicSpeed,
            CardGap = CardGap,
            SetScrolling = function(Enabled: boolean)
                Root.ScrollingEnabled = Enabled
            end,
        })

        MakeSegment(
            "Music",
            MusicSegment.Text or MusicSegment.Name or Config.MusicText,
            MusicSegment.Icon or Config.MusicIcon
        )
    end

    for _, Entry in ShownCustomSegments do
        local SegmentText = Entry.Data.Text or Entry.Data.Name or Entry.Key
        local SegmentIcon = Entry.Data.Icon or "file-text"

        Entry.Page = CreateContentPage()
        Pages[Entry.Key] = Entry.Page

        MakeSegment(Entry.Key, SegmentText, SegmentIcon)

        FillDescription(Library, Entry.Page, Entry.Data.Description, "No " .. tostring(SegmentText) .. " content yet.")
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
            --// The music player seek bar repaints every frame while its page is visible \\--
            if MusicPlayer and ActivePage == "Music" and Tab.Container.Visible then
                MusicPlayer.Update()
            end
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

        local DisplayNameText = tostring(LocalPlayer.DisplayName)
        local AccountNameText = tostring(LocalPlayer.Name)
        if IdentityHidden then
            DisplayNameText = IdentityMask
            AccountNameText = IdentityMask
        end
        SetText(Welcome, "Hello, " .. DisplayNameText)
        SetText(Username, GetGreeting(Config.Greetings) .. " | @" .. AccountNameText)
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
        Music = MusicPlayer,
        --// Dashboard:HopServer(Smallest) hops to a random (or the least populated) server
        HopServer = HopServer,
        --// Dashboard:HideIdentity(Hidden) hides the username & display name locally
        HideIdentity = SetIdentityHidden,
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

        --// Silent identity reset so the local character keeps its name display \\--
        if IdentityHidden then
            SetIdentityHidden(false, true)
        end

        if MusicPlayer then
            MusicPlayer.Destroy()
            MusicPlayer = nil
            Dashboard.Music = nil
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
