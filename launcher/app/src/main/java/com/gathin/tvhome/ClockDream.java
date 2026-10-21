package com.gathin.tvhome;

import android.service.dreams.DreamService;
import android.view.View;

/**
 * Screensaver: a large centred 24-hour clock over the screensaver artwork, with the brand and date below.
 * Static and cheap enough for a 1 GB TV.
 */
public class ClockDream extends DreamService {

    private View content;

    @Override
    public void onAttachedToWindow() {
        super.onAttachedToWindow();
        setInteractive(false);   // any key wakes the TV back to where it was
        setFullscreen(true);
        setScreenBright(false);
        setContentView(R.layout.dream_clock);
        content = findViewById(R.id.dreamContent);
    }

    @Override
    public void onDreamingStarted() {
        super.onDreamingStarted();
        content.setAlpha(0f);
        content.post(() -> content.animate().alpha(1f).setDuration(1200).start());
    }

    @Override
    public void onDreamingStopped() {
        content.animate().cancel();
        super.onDreamingStopped();
    }
}
