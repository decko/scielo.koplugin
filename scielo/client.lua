local JSON = require("json")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")

local Client = {
    crossref_url = "https://api.crossref.org/works",
    doi_url = "https://doi.org/",
    scielo_host = "www.scielo.br",
    max_redirects = 8,
    large_block_timeout = socketutil.LARGE_BLOCK_TIMEOUT,
    large_total_timeout = socketutil.LARGE_TOTAL_TIMEOUT,
    file_block_timeout = socketutil.FILE_BLOCK_TIMEOUT,
    file_total_timeout = socketutil.FILE_TOTAL_TIMEOUT,
}

function Client:_request(reqt, is_file)
    if is_file then
        socketutil:set_timeout(self.file_block_timeout, self.file_total_timeout)
    else
        socketutil:set_timeout(self.large_block_timeout, self.large_total_timeout)
    end
    local code, headers, status = socket.skip(1, http.request(reqt))
    socketutil:reset_timeout()
    return code, headers, status
end

function Client:getText(address)
    local sink = {}
    local code, headers, status = self:_request{
        url = address,
        sink = socketutil.table_sink(sink),
    }
    if headers == nil then
        logger.warn("SciELO: network error", code)
        return nil, "network"
    end
    if code ~= 200 then
        logger.warn("SciELO: HTTP error", code, status)
        return nil, "http", code
    end
    return table.concat(sink)
end

function Client:getJson(address)
    local body, err, code = self:getText(address)
    if not body then
        return nil, err, code
    end
    local ok, decoded = pcall(JSON.decode, body)
    if not ok or not decoded then
        logger.warn("SciELO: invalid JSON response")
        return nil, "json"
    end
    return decoded
end

function Client:followRedirects(address)
    local current = address
    for _ = 1, self.max_redirects do
        local code, headers = self:_request{
            url = current,
            redirect = false,
            sink = ltn12.sink.null(),
        }
        if headers == nil then
            logger.warn("SciELO: network error while resolving", current, code)
            return nil, "network"
        end
        local location = headers.location
        if location and (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) then
            current = url.absolute(current, location:gsub("%s", ""))
            logger.dbg("SciELO: redirected to", current)
        elseif code == 200 then
            return current
        else
            logger.warn("SciELO: could not resolve", current, code)
            return nil, "http", code
        end
    end
    return nil, "redirect_loop"
end

function Client:resolveInput(input)
    input = input:match("^%s*(.-)%s*$")
    if input == "" then
        return nil, "empty"
    end
    if input:match("^10%.") then
        return self:followRedirects(self.doi_url .. input)
    end
    if input:match("^[Ss]%d%d%d%d%-[%dXx]+$") then
        return self:followRedirects("https://www.scielo.br/scielo.php?script=sci_arttext&pid=" .. input:upper())
    end
    if input:match("^https?://") then
        return self:followRedirects(input)
    end
    if input:match("^www%.") or input:match("^[%w%-]+%.scielo%.br/") then
        return self:followRedirects("https://" .. input)
    end
    return nil, "unsupported"
end

local NAMED_ENTITIES = {
    amp = "&",
    apos = "'",
    gt = ">",
    lt = "<",
    quot = '"',
}

local function decodeEntities(text)
    text = text:gsub("&#x(%x+);", function(hex)
        local code = tonumber(hex, 16)
        if code and code <= 255 then
            return string.char(code)
        end
    end)
    text = text:gsub("&#(%d+);", function(dec)
        local code = tonumber(dec)
        if code and code <= 255 then
            return string.char(code)
        end
    end)
    return text:gsub("&(%a+);", function(name)
        return NAMED_ENTITIES[name] or "&" .. name .. ";"
    end)
end

function Client:parseCitationMeta(html)
    local meta = { authors = {} }
    for tag in html:gmatch("<meta[^>]+>") do
        local name = tag:match('name="([^"]+)"')
        local content = tag:match('content="([^"]*)"')
        if name and content and name:sub(1, 9) == "citation_" then
            content = decodeEntities(content)
            if name == "citation_title" then
                meta.title = content
            elseif name == "citation_author" then
                table.insert(meta.authors, content)
            elseif name == "citation_journal_title" then
                meta.journal = content
            elseif name == "citation_doi" then
                meta.doi = content
            elseif name == "citation_publication_date" then
                meta.date = content
            elseif name == "citation_volume" then
                meta.volume = content
            elseif name == "citation_number" then
                meta.issue = content
            elseif name == "citation_firstpage" then
                meta.firstpage = content
            elseif name == "citation_lastpage" then
                meta.lastpage = content
            elseif name == "citation_pdf_url" then
                meta.pdf_url = content
            elseif name == "citation_xml_url" then
                meta.xml_url = content
            elseif name == "citation_language" then
                meta.language = content
            elseif name == "citation_article_type" then
                meta.article_type = content
            end
        end
    end
    return meta
end

function Client:getArticle(address)
    local html, err, code = self:getText(address)
    if not html then
        return nil, err, code
    end
    local meta = self:parseCitationMeta(html)
    if not meta.title then
        return nil, "not_article"
    end
    meta.url = address
    return meta
end

function Client:isScieloBr(address)
    local parsed = url.parse(address)
    return parsed ~= nil and parsed.host == self.scielo_host
end

function Client:search(query, rows)
    local address = self.crossref_url
        .. "?query=" .. url.escape(query)
        .. "&filter=" .. url.escape("prefix:10.1590")
        .. "&rows=" .. tostring(rows or 10)
        .. "&select=" .. url.escape("DOI,title,container-title,issued")
    local data, err, code = self:getJson(address)
    if not data then
        return nil, err, code
    end
    local items = data.message and data.message.items
    if not items then
        return nil, "bad_response"
    end
    local results = {}
    for _, item in ipairs(items) do
        local title = item.title and item.title[1] or ""
        title = decodeEntities(title):gsub("<[^>]+>", ""):gsub("%s+", " ")
        local journal = item["container-title"] and item["container-title"][1] or ""
        local year
        local date_parts = item.issued and item.issued["date-parts"]
        if date_parts and date_parts[1] and date_parts[1][1] then
            year = tostring(date_parts[1][1])
        end
        table.insert(results, {
            title = title,
            journal = journal,
            year = year,
            doi = item.DOI,
        })
    end
    return results
end

function Client:download(address, filepath)
    local file = io.open(filepath, "wb")
    if not file then
        return nil, "io"
    end
    local code, headers, status = self:_request({
        url = address,
        sink = socketutil.file_sink(file),
        headers = {
            ["Accept"] = "application/pdf,application/octet-stream,*/*",
        },
    }, true)
    if headers == nil then
        file:close()
        os.remove(filepath)
        logger.warn("SciELO: download network error", code)
        return nil, "network"
    end
    if code ~= 200 then
        file:close()
        os.remove(filepath)
        logger.warn("SciELO: download HTTP error", code, status)
        return nil, "http", code
    end
    return filepath
end

return Client
