import React from "react";
import { useTranslation } from "react-i18next";
import { ToggleSwitch } from "../ui/ToggleSwitch";
import { useSettings } from "../../hooks/useSettings";

interface OverlayClockProps {
  descriptionMode?: "inline" | "tooltip";
  grouped?: boolean;
}

/** The small clock that appears in the island once a dictation runs long. */
export const OverlayClock: React.FC<OverlayClockProps> = React.memo(
  ({ descriptionMode = "tooltip", grouped = false }) => {
    const { t } = useTranslation();
    const { getSetting, updateSetting, isUpdating } = useSettings();
    const enabled = getSetting("overlay_clock") ?? true;
    return (
      <ToggleSwitch
        checked={enabled}
        onChange={(v) => updateSetting("overlay_clock", v)}
        isUpdating={isUpdating("overlay_clock")}
        label={t("settings.general.overlayClock.label")}
        description={t("settings.general.overlayClock.description")}
        descriptionMode={descriptionMode}
        grouped={grouped}
      />
    );
  },
);
