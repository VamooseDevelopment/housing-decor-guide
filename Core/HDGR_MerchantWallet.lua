-- HDG.MerchantWallet
-- ============================================================================
-- What a vendor purchase costs and what the player holds to pay it, as plain
-- data. Pure: no Blizzard calls and no state reads -- callers pass the costs and
-- the wallet in. The merchant selectors (Buy All summary, vendor sidebar), the
-- quantity picker and the buy queue's pre-flight all sum through here, so the
-- confirm, the footer, the picker and the refusal can never disagree.
--
-- A cost component (MerchantObserver bakes these per vendor slot):
--   gold     { kind = "gold",     key = "gold",          amount = copper }
--   currency { kind = "currency", key = "currency:<id>", id, amount, name, icon }
--   item     { kind = "item",     key = "item:<id>",     id, amount, name, icon }
-- A slot can mix them (gold + a currency). The wallet is { [key] = balance }.

HDG = HDG or {}
HDG.MerchantWallet = HDG.MerchantWallet or {}
local W = HDG.MerchantWallet

W.GOLD_KEY = "gold"

-- Bought from: the server says the slot is purchasable AND its price was read.
-- An empty costs list is a slot still streaming in (or a free one); either way
-- HDG does not buy what it cannot price.
function W.IsBuyable(stock)
    return stock.isPurchasable and #stock.costs > 0
end

local KIND_ORDER = { gold = 1, currency = 2, item = 3 }

local function _walletOrder(a, b)
    local ka, kb = KIND_ORDER[a.kind], KIND_ORDER[b.kind]
    if ka ~= kb then return ka < kb end
    return a.key < b.key
end

local function _addSpend(byKey, list, cost, qty)
    local e = byKey[cost.key]
    if not e then
        e = { key = cost.key, kind = cost.kind, id = cost.id, name = cost.name,
              icon = cost.icon, amount = 0 }
        byKey[cost.key] = e
        list[#list + 1] = e
    end
    e.amount = e.amount + cost.amount * qty
end

-- Per-wallet spend of rows ({ costs, qty }, ...), gold first, then currencies,
-- then items: { { key, kind, id, name, icon, amount }, ... }.
function W.Spend(rows)
    local byKey, list = {}, {}
    for _, r in ipairs(rows) do
        for _, cost in ipairs(r.costs) do _addSpend(byKey, list, cost, r.qty) end
    end
    table.sort(list, _walletOrder)
    return list
end

-- Stamp each spend entry with the balance it draws on: have, short (cannot pay),
-- pct (share of the balance) and flagged (affordable, but MORE than the warn
-- fraction of it). Returns the same list.
function W.Assess(spend, wallet)
    local warn = HDG.Constants.MERCHANT_SPEND_WARN_FRACTION
    for _, e in ipairs(spend) do
        -- A missing balance reads as none held, which REFUSES the buy -- the safe
        -- way round. It happens only when rows built before a rescan name a
        -- payment the vendor in front of you no longer charges.
        e.have    = wallet[e.key] or 0   -- exception(nullable): stale rows can name a payment the open vendor no longer takes
        e.short   = e.amount > e.have
        e.flagged = not e.short and e.amount > e.have * warn
        -- WoW Lua errors on x/0: a zero balance is short whenever anything is spent.
        e.pct     = e.have > 0 and math.floor(e.amount * 100 / e.have) or 0
    end
    return spend
end

-- The first wallet the spend cannot cover, or nil.
function W.FirstShort(spend)
    for _, e in ipairs(spend) do
        if e.short then return e end
    end
    return nil   -- exception(nullable): every wallet covers its share
end

-- How many of one slot the wallet pays for: the tightest component decides.
function W.MaxAffordable(costs, wallet)
    if #costs == 0 then return 0 end
    local most = math.huge
    for _, cost in ipairs(costs) do
        local have = wallet[cost.key] or 0   -- exception(nullable): see Assess
        most = math.min(most, math.floor(have / cost.amount))
    end
    return most
end

-- ===== Text =================================================================
-- Runtime-only (Theme + Locale); callers that are selectors declare
-- account.config.scheme and account.config.locale.

local function _colorToken(e)
    local tokens = HDG.Constants.MERCHANT_COST_COLOR_TOKENS
    if e.kind == "currency" and e.id == HDG.Constants.COUPON_CURRENCY_ID then return tokens.coupon end
    return tokens[e.kind]
end

-- Display name of the wallet a cost draws on.
function W.Name(e)
    if e.kind == "gold" then return HDG.Locale:Get("MERCHANT_GOLD") end
    return e.name
end

-- The amount alone, uncoloured: coins for gold, a plain number otherwise. Zero is
-- written out -- "you have 0" -- where the Format helpers leave it blank.
function W.PlainAmount(e, amount)
    if e.kind == "gold" then
        if amount == 0 then return HDG.Format.FormatGoldZero(0) end
        return HDG.Format.FormatCopper(amount)
    end
    if amount == 0 then return "0" end
    return HDG.Format.FormatAmount(amount)
end

-- The amount in its kind's colour, with the payment's icon: "75 <icon>".
function W.FormatAmount(e, amount)
    local text = W.PlainAmount(e, amount)
    if e.kind ~= "gold" then text = text .. " " .. HDG.Format.IconMarkup(e.icon, 14) end
    return HDG.Theme:ColorCode(_colorToken(e)) .. text .. "|r"
end

-- A whole cost list at a quantity: "60 <coin> + 10 <icon>".
function W.FormatCosts(costs, qty)
    local parts = {}
    for _, cost in ipairs(costs) do parts[#parts + 1] = W.FormatAmount(cost, cost.amount * qty) end
    return table.concat(parts, " + ")
end

-- A spend list as one line, named: "1,315 <coin>  .  320 <icon> Undercoin".
function W.SpendLine(spend)
    local parts = {}
    for _, e in ipairs(spend) do
        local text = W.FormatAmount(e, e.amount)
        if e.kind ~= "gold" then text = text .. " " .. e.name end
        parts[#parts + 1] = text
    end
    return table.concat(parts, "   ")
end

-- "This uses 80% of your Undercoin (320 of 400)." for each flagged wallet.
function W.WarnLines(spend)
    local lines = {}
    for _, e in ipairs(spend) do
        if e.flagged then
            lines[#lines + 1] = HDG.Locale:Get("MERCHANT_SPEND_WARN"):format(
                e.pct, W.Name(e), W.PlainAmount(e, e.amount), W.PlainAmount(e, e.have))
        end
    end
    return lines
end

-- "Not enough Undercoin: needs 320, you have 100."
function W.ShortLine(e)
    return HDG.Locale:Get("MERCHANT_SHORT"):format(
        W.Name(e), W.PlainAmount(e, e.amount), W.PlainAmount(e, e.have))
end
