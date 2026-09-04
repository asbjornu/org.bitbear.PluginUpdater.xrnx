-- Maps each upgrade outcome to a colour, short label, and hover tooltip for the
-- dialog's "Result" column. Kept separate from the dialog so the mapping can be
-- unit-tested and reused without the rest of the user interface.

local up_result_display = {}

-- One of four colour categories the user asked for: green = fully upgraded,
-- yellow = partially upgraded, red = failed, gray = not upgraded.
local RESULT_COLORS = {
  green = { 0, 180, 0 },
  yellow = { 200, 170, 0 },
  red = { 220, 60, 60 },
  gray = { 150, 150, 150 },
}

local RESULT_STYLES = {
  ["upgraded-with-parameters"] = {
    color = RESULT_COLORS.green, label = "Upgraded",
    tip = "Replacement loaded and the original preset/state was transferred exactly.",
  },
  ["upgraded-name-matched-preset"] = {
    color = RESULT_COLORS.green, label = "Upgraded",
    tip = "Replacement loaded with a matching factory preset of the same name; your patch should be intact.",
  },
  ["upgraded-parameter-synth"] = {
    color = RESULT_COLORS.yellow, label = "Partial",
    tip = "Replacement loaded; matching parameters were re-applied by name, so some "
      .. "settings may differ from the original.",
  },
  ["upgraded-default"] = {
    color = RESULT_COLORS.yellow, label = "Partial",
    tip = "Replacement loaded, but the original state could not be carried over, so it is at its default patch.",
  },
  ["up-to-date"] = {
    color = RESULT_COLORS.gray, label = "Current",
    tip = "Already the selected replacement; nothing to change.",
  },
  ["skipped-up-to-date"] = {
    color = RESULT_COLORS.gray, label = "Current",
    tip = "Already up to date; no replacement needed.",
  },
  ["skipped-no-candidate-broken"] = {
    color = RESULT_COLORS.gray, label = "No match",
    tip = "No replacement plugin could be found for this (broken) plugin.",
  },
  ["skipped-transfer-rejected"] = {
    color = RESULT_COLORS.red, label = "Failed",
    tip = "The replacement could not be loaded or inserted.",
  },
  ["error"] = {
    color = RESULT_COLORS.red, label = "Failed",
    tip = "The upgrade failed with an error.",
  },
}

local RESULT_PENDING = {
  color = RESULT_COLORS.gray, label = "Pending",
  tip = "Not upgraded yet. Choose a replacement and press Upgrade.",
}

-- Return the display style (colour, label, tooltip) for a given upgrade status
-- string, falling back to a gray "Unknown" style for anything unrecognised.
local function result_style(status)
  if not status or status == "" then
    return RESULT_PENDING
  end
  return RESULT_STYLES[status] or {
    color = RESULT_COLORS.gray, label = "Unknown",
    tip = "Unrecognised result: " .. tostring(status),
  }
end

-- Paint the given result text control from an upgrade outcome. The text colour
-- is the category signal; the tooltip is the human-readable explanation.
local function set_result(result_text, status, detail)
  if not result_text or not result_text.text then
    return
  end
  local style = result_style(status)
  result_text.text = "● " .. style.label
  result_text.color = style.color
  local tip = style.tip
  if detail and detail ~= "" then
    tip = tip .. "\n\n" .. detail
  end
  result_text.tooltip = tip
end

up_result_display.RESULT_COLORS = RESULT_COLORS
up_result_display.RESULT_STYLES = RESULT_STYLES
up_result_display.result_style = result_style
up_result_display.set_result = set_result

return up_result_display
