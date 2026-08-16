import React, { useState } from "react";
import { useTranslation } from "react-i18next";
import NoiWordmark from "../../icons/NoiWordmark";
import { SimpleSection } from "../../ui/SimpleSection";
import { ShortcutInput } from "../ShortcutInput";
import { PushToTalk } from "../PushToTalk";
import { MicrophoneSelector } from "../MicrophoneSelector";
import { ShowOverlay } from "../ShowOverlay";
import { OverlayClock } from "../OverlayClock";
import { AutostartToggle } from "../AutostartToggle";
import { AudioFeedback } from "../AudioFeedback";
import { ModelSettingsCard } from "../general/ModelSettingsCard";
import { PostProcessingToggle } from "../PostProcessingToggle";
import { PostProcessingSettingsApi } from "../post-processing/PostProcessingSettings";
import { HistoryLimit } from "../HistoryLimit";
import { RecordingRetentionPeriodSelector } from "../RecordingRetentionPeriod";
import { HistorySettings } from "../history/HistorySettings";
import { NotesSection } from "../notes/NotesSection";
import { useSettings } from "../../../hooks/useSettings";

/**
 * Noi's settings: one column, four sections, the few things that matter.
 * Everything else lives in the full (Handy) settings, one link away.
 */
export const SimpleSettings: React.FC<{
  onShowFull: (section?: "models") => void;
}> = ({ onShowFull }) => {
  const { t } = useTranslation();
  const { getSetting } = useSettings();
  const [showHistory, setShowHistory] = useState(false);
  const refineOn = getSetting("post_process_enabled") ?? false;

  return (
    <div className="simple max-w-xl w-full mx-auto pb-16">
      <div className="px-4 pt-2 pb-2">
        <NoiWordmark width={96} />
      </div>

      <SimpleSection title={t("simple.general")}>
        <ShortcutInput shortcutId="transcribe" grouped={true} />
        <ShortcutInput shortcutId="refine_selection" grouped={true} />
        <PushToTalk descriptionMode="tooltip" grouped={true} />
        <MicrophoneSelector descriptionMode="tooltip" grouped={true} />
        <ShowOverlay descriptionMode="tooltip" grouped={true} />
        <OverlayClock descriptionMode="tooltip" grouped={true} />
        <AutostartToggle descriptionMode="tooltip" grouped={true} />
        <AudioFeedback descriptionMode="tooltip" grouped={true} />
      </SimpleSection>

      <div className="mt-8">
        <ModelSettingsCard />
        <div className="px-4 py-2">
          <button
            type="button"
            className="text-sm text-logo-primary hover:underline cursor-pointer"
            onClick={() => onShowFull("models")}
          >
            {t("simple.manageModels")}
          </button>
        </div>
      </div>

      <SimpleSection title={t("simple.refine")}>
        <PostProcessingToggle descriptionMode="tooltip" grouped={true} />
        {refineOn && <PostProcessingSettingsApi />}
      </SimpleSection>

      <SimpleSection title={t("simple.notes")}>
        <NotesSection />
      </SimpleSection>

      <SimpleSection title={t("simple.history")}>
        <HistoryLimit descriptionMode="tooltip" grouped={true} />
        <RecordingRetentionPeriodSelector
          descriptionMode="tooltip"
          grouped={true}
        />
        <div className="px-4 py-2">
          <button
            type="button"
            className="text-sm text-logo-primary hover:underline cursor-pointer"
            onClick={() => setShowHistory((v) => !v)}
          >
            {showHistory ? t("simple.hideHistory") : t("simple.showHistory")}
          </button>
        </div>
        {showHistory && (
          <div className="px-2 py-2">
            <HistorySettings />
          </div>
        )}
      </SimpleSection>

      <div className="px-4 mt-8">
        <button
          type="button"
          className="text-sm text-mid-gray hover:text-text cursor-pointer"
          onClick={() => onShowFull()}
        >
          {t("simple.advanced")}
        </button>
      </div>
    </div>
  );
};
