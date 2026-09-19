local Button = require("ui/widget/button")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

local Client = require("scielo.client")

local ERROR_MESSAGES = {
    empty = _("Please enter a URL, a DOI or a SciELO article code."),
    http = _("The server returned an error."),
    io = _("Could not write to the download folder."),
    json = _("Could not read the server response."),
    network = _("Network error. Check your connection and try again."),
    not_article = _("The page does not look like a SciELO article."),
    redirect_loop = _("Too many redirects."),
    unsupported = _("Enter a www.scielo.br article URL, a DOI or a SciELO article code."),
}

local SciELO = WidgetContainer:extend{
    name = "scielo",
    is_doc_only = false,
    settings_file = DataStorage:getSettingsDir() .. "/scielo.lua",
}

function SciELO:init()
    self.settings = LuaSettings:open(self.settings_file)
    self.client = Client
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self:registerZenOSHomeItem()
end

function SciELO:onDispatcherRegisterActions()
    Dispatcher:registerAction("scielo_search", {
        category = "none",
        event = "SciELOSearch",
        title = _("SciELO search"),
        general = true,
    })
end

function SciELO:addToMainMenu(menu_items)
    menu_items.scielo = {
        text = _("SciELO"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Search articles"),
                callback = function()
                    self:showSearchDialog()
                end,
            },
            {
                text = _("Open article from URL, DOI or code"),
                callback = function()
                    self:showInputDialog()
                end,
            },
            {
                text = _("Go to download folder"),
                enabled_func = function()
                    local directory = self:getDownloadDirectory()
                    return directory ~= nil and lfs.attributes(directory, "mode") == "directory"
                end,
                callback = function()
                    self:onGoToScieloDirectory()
                end,
            },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text_func = function()
                            local directory = self:getDownloadDirectory()
                            return T(_("Download folder: %1"),
                                directory and filemanagerutil.abbreviate(directory) or _("not set"))
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:chooseDownloadDirectory(touchmenu_instance)
                        end,
                    },
                    {
                        text_func = function()
                            return T(_("Search results per page: %1"), self:getResultsPerPage())
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:showResultsPerPageDialog(touchmenu_instance)
                        end,
                    },
                    {
                        text = _("Help"),
                        keep_menu_open = true,
                        callback = function()
                            self:showHelp()
                        end,
                    },
                },
            },
        },
    }
end

function SciELO:getDownloadDirectory()
    local directory = self.settings:readSetting("download_directory")
    if directory and directory ~= "" then
        return directory
    end
end

function SciELO:getResultsPerPage()
    return self.settings:readSetting("results_per_page") or 10
end

function SciELO:saveSetting(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function SciELO:runWhenOnline(callback)
    NetworkMgr:runWhenOnline(callback)
end

function SciELO:showError(message, err)
    logger.warn("SciELO:", message, err)
    UIManager:show(InfoMessage:new{
        text = T(_("%1\n\n%2"), message, ERROR_MESSAGES[err] or err or _("Unknown error.")),
    })
end

function SciELO:showHelp()
    UIManager:show(InfoMessage:new{
        text = _([[Search open access articles on www.scielo.br and download their PDFs.

Search uses Crossref (crossref.org) restricted to SciELO DOIs. Results are resolved to www.scielo.br, where article metadata and the PDF are fetched.

You can also open an article directly by pasting its URL, its DOI, or its SciELO code (e.g. S0034-89102013000100001).]]),
    })
end

function SciELO:chooseDownloadDirectory(touchmenu_instance)
    require("ui/downloadmgr"):new{
        onConfirm = function(path)
            self:saveSetting("download_directory", path)
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    }:chooseDir()
end

function SciELO:showResultsPerPageDialog(touchmenu_instance)
    self.results_dialog = InputDialog:new{
        title = _("Search results per page"),
        input = tostring(self:getResultsPerPage()),
        input_type = "number",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.results_dialog)
                    end,
                },
                {
                    text = _("Set"),
                    is_enter_default = true,
                    callback = function()
                        local value = tonumber(self.results_dialog:getInputText())
                        if value and value > 0 and value <= 50 then
                            self:saveSetting("results_per_page", value)
                            UIManager:close(self.results_dialog)
                            if touchmenu_instance then
                                touchmenu_instance:updateItems()
                            end
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Please enter a number between 1 and 50."),
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(self.results_dialog)
end

function SciELO:showSearchDialog()
    self.search_dialog = InputDialog:new{
        title = _("Search SciELO articles"),
        input = self.settings:readSetting("last_query") or "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.search_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = self.search_dialog:getInputText()
                        UIManager:close(self.search_dialog)
                        if query and query ~= "" then
                            self:saveSetting("last_query", query)
                            self:search(query)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(self.search_dialog)
    self.search_dialog:onShowKeyboard()
end

function SciELO:showInputDialog()
    self.input_dialog = InputDialog:new{
        title = _("Article URL, DOI or SciELO code"),
        input = self.settings:readSetting("last_input") or "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.input_dialog)
                    end,
                },
                {
                    text = _("Open"),
                    is_enter_default = true,
                    callback = function()
                        local input = self.input_dialog:getInputText()
                        UIManager:close(self.input_dialog)
                        if input and input ~= "" then
                            self:saveSetting("last_input", input)
                            self:openFromInput(input)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(self.input_dialog)
    self.input_dialog:onShowKeyboard()
end

function SciELO:showResultsMenu(title, items)
    local menu
    menu = Menu:new{
        title = title,
        item_table = items,
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
        items_max_lines = 3,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        close_callback = function()
            UIManager:close(menu)
        end,
    }
    UIManager:show(menu)
end

function SciELO:search(query)
    local rows = self:getResultsPerPage()
    self:runWhenOnline(function()
        local info = InfoMessage:new{ text = T(_("Searching SciELO for “%1”…"), query) }
        UIManager:show(info)
        UIManager:forceRePaint()
        local results, err = self.client:search(query, rows)
        UIManager:close(info)
        if not results then
            self:showError(_("Search failed."), err)
            return
        end
        if #results == 0 then
            UIManager:show(InfoMessage:new{ text = _("No results found.") })
            return
        end
        local items = {}
        for _, result in ipairs(results) do
            local text = result.title
            local subtitle = {}
            if result.journal and result.journal ~= "" then
                table.insert(subtitle, result.journal)
            end
            if result.year then
                table.insert(subtitle, result.year)
            end
            if #subtitle > 0 then
                text = text .. "\n" .. table.concat(subtitle, " · ")
            end
            table.insert(items, {
                text = text,
                callback = function()
                    self:openSearchResult(result)
                end,
            })
        end
        self:showResultsMenu(_("SciELO search results"), items)
    end)
end

function SciELO:openSearchResult(result)
    if not result.doi then
        UIManager:show(InfoMessage:new{ text = _("This result has no DOI.") })
        return
    end
    self:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Fetching article information…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local address, err = self.client:resolveInput(result.doi)
        local meta
        if address then
            if self.client:isScieloBr(address) then
                meta, err = self.client:getArticle(address)
            else
                err = "not_scielo_br"
            end
        end
        UIManager:close(info)
        if not meta then
            if err == "not_scielo_br" then
                UIManager:show(InfoMessage:new{
                    text = _("This article is not hosted on www.scielo.br."),
                })
            else
                self:showError(_("Could not fetch the article."), err)
            end
            return
        end
        self:confirmDownload(meta)
    end)
end

function SciELO:openFromInput(input)
    self:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Fetching article information…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local address, err = self.client:resolveInput(input)
        local meta
        if address then
            meta, err = self.client:getArticle(address)
        end
        UIManager:close(info)
        if not meta then
            self:showError(_("Could not fetch the article."), err)
            return
        end
        self:confirmDownload(meta)
    end)
end

function SciELO:confirmDownload(meta)
    if not meta.pdf_url then
        UIManager:show(InfoMessage:new{
            text = T(_("No PDF available for “%1”."), meta.title),
        })
        return
    end
    local lines = { meta.title }
    if #meta.authors > 0 then
        table.insert(lines, table.concat(meta.authors, "; "))
    end
    local publication = {}
    if meta.journal then
        table.insert(publication, meta.journal)
    end
    if meta.volume then
        table.insert(publication, T(_("v. %1"), meta.volume))
    end
    if meta.issue then
        table.insert(publication, T(_("n. %1"), meta.issue))
    end
    if meta.date then
        table.insert(publication, meta.date)
    end
    if #publication > 0 then
        table.insert(lines, table.concat(publication, " "))
    end
    if meta.doi then
        table.insert(lines, meta.doi)
    end
    table.insert(lines, _("Download this article?"))
    UIManager:show(ConfirmBox:new{
        text = table.concat(lines, "\n\n"),
        ok_text = _("Download"),
        ok_callback = function()
            self:downloadArticle(meta)
        end,
    })
end

function SciELO:downloadArticle(meta)
    local directory = self:getDownloadDirectory()
    if not directory then
        UIManager:show(InfoMessage:new{
            text = _("Please set a download folder in the SciELO settings."),
        })
        self:chooseDownloadDirectory()
        return
    end
    util.makePath(directory)
    local title = meta.title
    if not title or title == "" then
        title = "scielo-article"
    end
    local filename = util.getSafeFilename(title, directory, 230, 0) .. ".pdf"
    local filepath = self:uniquePath(ffiUtil.joinPath(directory, filename))
    self:runWhenOnline(function()
        local info = InfoMessage:new{ text = T(_("Downloading “%1”…"), meta.title) }
        UIManager:show(info)
        UIManager:forceRePaint()
        local saved, err = self.client:download(meta.pdf_url, filepath)
        UIManager:close(info)
        if not saved then
            self:showError(_("Download failed."), err)
            return
        end
        self:refreshFileManager()
        UIManager:show(ConfirmBox:new{
            text = T(_("Article saved to:\n%1\n\nOpen it now?"), filemanagerutil.abbreviate(saved)),
            ok_text = _("Open"),
            ok_callback = function()
                self:openDocument(saved)
            end,
        })
    end)
end

function SciELO:uniquePath(filepath)
    if not lfs.attributes(filepath, "mode") then
        return filepath
    end
    local base, extension = filepath:match("^(.*)(%.pdf)$")
    if not base then
        return filepath
    end
    local index = 1
    while true do
        local candidate = string.format("%s (%d)%s", base, index, extension)
        if not lfs.attributes(candidate, "mode") then
            return candidate
        end
        index = index + 1
    end
end

function SciELO:refreshFileManager()
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:onRefresh()
    end
end

function SciELO:openDocument(filepath)
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(filepath)
end

function SciELO:onGoToScieloDirectory()
    local directory = self:getDownloadDirectory()
    if not directory then
        UIManager:show(InfoMessage:new{
            text = _("Please set a download folder in the SciELO settings."),
        })
        return true
    end
    if self.ui.document then
        self.ui:onClose()
    end
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:reinit(directory)
    else
        FileManager:showFiles(directory)
    end
    return true
end

function SciELO:onSciELOSearch()
    self:showSearchDialog()
    return true
end

function SciELO:registerZenOSHomeItem()
    local register = rawget(_G, "__ZENOS_REGISTER_HOME_ITEM")
        or rawget(_G, "__ZEN_UI_REGISTER_HOME_ITEM")
    if type(register) ~= "function" then
        return false
    end
    local ok = pcall(register, "scielo.search", function(ctx)
        return self:buildZenOSHomeItem(ctx)
    end, { label = _("Search on SciELO"), size = "s" })
    if ok then
        logger.dbg("SciELO: registered ZenOS home item")
    end
    return ok
end

function SciELO:buildZenOSHomeItem(ctx)
    ctx = ctx or {}
    local border = Size.border.button
    local padding = Size.padding.button
    return Button:new{
        text = _("Search on SciELO"),
        text_font_size = 18,
        width = ctx.width,
        height = math.max(1, (ctx.height or 1) - 2 * (border + padding)),
        callback = function()
            self:showSearchDialog()
        end,
    }
end

function SciELO:onZenOSReady()
    self:registerZenOSHomeItem()
    return true
end

function SciELO:onZenUIReady()
    self:registerZenOSHomeItem()
    return true
end

return SciELO
