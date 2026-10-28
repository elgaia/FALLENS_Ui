--// DashboardManager addon for the Obsidian UI Library (FALLENS_Ui)
--// Adds a modern dashboard tab similar to modern UI dashboards:
--//    profile card (avatar + greeting), segment bar, server / discord / executor / friends
--//    cards with live stats and custom segment pages (changelog, script info, etc.)

local cloneref = (cloneref or clonereference or function(instance: any)
    return instance
end)

local HttpService: HttpService = cloneref(game:GetService("HttpService"))
local Players: Players = cloneref(game:GetService("Players"))
local RunService: RunService = cloneref(game:GetService("RunService"))
local TweenService: TweenService = cloneref(game:GetService("TweenService"))
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
        if Key ~= "Details" and Key ~= 1 and typeof(Key) == "string" and typeof(SegmentData) == "table" then
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
    VisibleSegmentCount = (ShowDetailsSegment and 1 or 0) + #ShownCustomSegments

    if VisibleSegmentCount <= 0 then
        ShowDetailsSegment = true
        VisibleSegmentCount = 1
    end

    --// Pages + segment buttons \\--
    local CardGap = 10
    local ContentHeight = 154 + CardGap + 112 --// tallest column: server + discord cards

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

    --// Custom segment pages (mirroring the modern UI segments: Script, UI, Changelog, ...) \\--
    if ShowDetailsSegment then
        local DetailsSegment = SegmentConfig.Details or SegmentConfig[1] or {}
        MakeSegment(
            "Details",
            DetailsSegment.Text or DetailsSegment.Name or Config.DetailsText,
            DetailsSegment.Icon or Config.DetailsIcon
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
