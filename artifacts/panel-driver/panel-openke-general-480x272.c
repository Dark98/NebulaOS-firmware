/*
 * OpenKE ke-mainline-klipper - best-effort panel driver for the real Ender 3 V3
 * KE Nebula Pad's 480x272 parallel-RGB TFT panel.
 *
 * The real device runs this panel via Creality's own closed `lcd_general_480x272.ko`
 * (no source ever published, see ANALYSIS in this workspace's FIRMWARE.md sec 7/9) -
 * this is a from-scratch driver for the ingenicfb "fb_stage" framework (the real,
 * complete, GPLv2 Ingenic display driver this workspace ported forward from the
 * 4.4.94 SDK to 6.6, see FIRMWARE.md sec 8), modeled on this SDK's own
 * panel-st7701s-rgb666.c (a real, complete LCD_TYPE_TFT example) - simplified
 * down to just the three required lcd_panel_ops callbacks (init/enable/disable),
 * since a plain "general" panel needs no command-interface init sequence the
 * way that example's smart-controller chip does, and no generic lcd-class
 * registration either (not required for ingenicfb_register_panel() to work).
 *
 * CONFIRMED from the real live device (read-only SSH, FIRMWARE.md sec 9):
 *   gpio_lcd_power_en = PC21
 *   gpio_lcd_rst      = PB16
 *   mode              = 480x272p-60 (confirmed via /sys/class/graphics/fb0/modes)
 *
 * CONFIRMED, later, by pulling the real device's own closed lcd_general_480x272.ko
 * and soc_fb.ko off the live printer (read-only scp) and disassembling them with a
 * real MIPS-capable objdump (host objdump has no MIPS backend; used the
 * pellcorp/k1-bash-build Docker image's toolchain instead) - not a datasheet, but
 * real bytes/code from the actual working driver for this exact panel:
 *   - xres=480, yres=272 at struct offsets +8/+12 - confirmed via jzfb_register_lcd's
 *     own range-check code (`(x-32) < 2016`), matching the live fb0 mode exactly.
 *   - Six adjacent struct fields (offsets 0x14/0x18/0x1c/0x20/0x24/0x28) all hold the
 *     literal value 20, and are summed in pairs inside jzfb_register_lcd in a pattern
 *     consistent with computing htotal/vtotal from margins+sync widths - strong
 *     circumstantial evidence the real left/right/upper/lower margins and hsync/vsync
 *     pulse widths are uniformly 20, not the asymmetric generic-reference values this
 *     driver used before (margins=2, hsync=41, vsync=10). Field order among the six
 *     couldn't be fully pinned down without the real header, but since all six are
 *     identical, that ambiguity doesn't actually matter here.
 *   - pixclock below is DERIVED from htotal=480+3*20=540, vtotal=272+3*20=332, and the
 *     confirmed 60Hz refresh (`htotal*vtotal*refresh`), not read directly as a static
 *     constant - the real driver computes this same value at registration time rather
 *     than storing it, per the disassembly.
 *   - Struct offset 0x34 (lcd "mode"/type selector) reads as 0, consistent with this
 *     driver's own LCD_TYPE_TFT=0 assumption.
 *   - A physical-size field pair (53mm, 95mm) was also found nearby, closely matching
 *     (within 1mm) this driver's already-guessed 54x95mm - left unchanged.
 *
 * STILL NOT CONFIRMED:
 *   - GPIO active-high/low polarity - hardcoded active-high here (this kernel's
 *     of_get_named_gpio() doesn't return the DT flags cell), easy to invert in
 *     this file if the panel powers up backwards.
 *   - Color depth/mode (RGB888 assumed here - could be RGB565/RGB666 on the real
 *     panel; wrong here would show as color-channel banding/miscoloring, not
 *     hardware risk).
 *   - The exact semantic identity of each of the six offset-20 fields (which is
 *     left_margin vs. hsync_len, etc.) - moot for correctness since all six carry
 *     the same value, but means this mapping is evidence-based, not header-verified.
 *
 * This file may be distributed under the terms of the GNU GPLv2 license.
 */

#include <linux/init.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/gpio.h>
#include <linux/of_gpio.h>
#include <linux/delay.h>

#include "../include/ingenicfb.h"

struct panel_dev {
	struct device *dev;
	int vdd_en_gpio;
	int rst_gpio;
};

static struct panel_dev *panel;

static void panel_init(void *p)
{
	/* Nothing to do here for a plain RGB panel - all real setup happens in
	 * enable(), matching how the ingenicfb core calls init() once at probe
	 * time and enable()/disable() on every blank/unblank. */
}

static void panel_enable(void *p)
{
	if (!panel)
		return;
	if (gpio_is_valid(panel->vdd_en_gpio))
		gpio_direction_output(panel->vdd_en_gpio, 1);
	/* Real panel reset pulse timing not confirmed - 10ms low, 10ms settle
	 * is a conservative, commonly-used default for this class of panel,
	 * not read from a datasheet for this exact part. */
	if (gpio_is_valid(panel->rst_gpio)) {
		gpio_direction_output(panel->rst_gpio, 0);
		mdelay(10);
		gpio_direction_output(panel->rst_gpio, 1);
		mdelay(10);
	}
}

static void panel_disable(void *p)
{
	if (!panel)
		return;
	if (gpio_is_valid(panel->vdd_en_gpio))
		gpio_direction_output(panel->vdd_en_gpio, 0);
}

static struct lcd_panel_ops panel_ops = {
	.init = panel_init,
	.enable = panel_enable,
	.disable = panel_disable,
};

/* Timing derived from disassembling the real device's own lcd_general_480x272.ko/
 * soc_fb.ko (see the module header comment) - margins/sync widths are the real
 * device's own values (uniformly 20), pixclock is computed from those via the
 * standard htotal*vtotal*refresh relationship, matching this driver's own KHz
 * convention (confirmed against panel-st7701s-rgb666.c), not the picosecond
 * convention plain Linux fb.h normally uses. */
static struct fb_videomode panel_modes[] = {
	[0] = {
		.name           = "480x272",
		.refresh        = 60,
		.xres           = 480,
		.yres           = 272,
		.pixclock       = 10753,
		.left_margin    = 20,
		.right_margin   = 20,
		.upper_margin   = 20,
		.lower_margin   = 20,
		.hsync_len      = 20,
		.vsync_len      = 20,
		.vmode          = FB_VMODE_NONINTERLACED,
		.flag           = 0,
	},
};

static struct tft_config openke_general_480x272_cfg = {
	.pix_clk_inv = 0,
	.de_dl = 0,
	.sync_dl = 0,
	.color_even = TFT_LCD_COLOR_EVEN_RGB,
	.color_odd = TFT_LCD_COLOR_ODD_RGB,
	.mode = TFT_LCD_MODE_PARALLEL_888,
};

struct lcd_panel lcd_panel = {
	.name = "openke_general_480x272",
	.num_modes = ARRAY_SIZE(panel_modes),
	.modes = panel_modes,
	.bpp = 32,
	.width = 95,   /* physical panel size in mm - not confirmed, cosmetic only */
	.height = 54,

	.lcd_type = LCD_TYPE_TFT,
	.tft_config = &openke_general_480x272_cfg,

	.dither_enable = 0,
	.ops = &panel_ops,
};

static int panel_probe(struct platform_device *pdev)
{
	struct device_node *np = pdev->dev.of_node;
	int ret;

	panel = devm_kzalloc(&pdev->dev, sizeof(*panel), GFP_KERNEL);
	if (!panel)
		return -ENOMEM;
	panel->dev = &pdev->dev;

	panel->vdd_en_gpio = of_get_named_gpio(np, "ingenic,vdd-en-gpio", 0);
	if (gpio_is_valid(panel->vdd_en_gpio)) {
		ret = devm_gpio_request_one(&pdev->dev, panel->vdd_en_gpio,
					     GPIOF_DIR_OUT, "lcd_vdd_en");
		if (ret < 0) {
			dev_err(&pdev->dev, "Failed to request vdd_en pin!\n");
			return ret;
		}
	} else {
		dev_warn(&pdev->dev, "invalid gpio vdd_en: %d\n", panel->vdd_en_gpio);
	}

	panel->rst_gpio = of_get_named_gpio(np, "ingenic,rst-gpio", 0);
	if (gpio_is_valid(panel->rst_gpio)) {
		ret = devm_gpio_request_one(&pdev->dev, panel->rst_gpio,
					     GPIOF_DIR_OUT, "lcd_rst");
		if (ret < 0) {
			dev_err(&pdev->dev, "Failed to request rst pin!\n");
			return ret;
		}
	} else {
		dev_warn(&pdev->dev, "invalid gpio rst: %d\n", panel->rst_gpio);
	}

	ret = ingenicfb_register_panel(&lcd_panel);
	if (ret < 0) {
		dev_err(&pdev->dev, "Failed to register lcd panel!\n");
		return ret;
	}

	return 0;
}

static int panel_remove(struct platform_device *pdev)
{
	panel_disable(NULL);
	return 0;
}

static const struct of_device_id panel_of_match[] = {
	{ .compatible = "openke,general-480x272", },
	{},
};
MODULE_DEVICE_TABLE(of, panel_of_match);

static struct platform_driver panel_driver = {
	.probe  = panel_probe,
	.remove = panel_remove,
	.driver = {
		.name = "openke_general_480x272",
		.of_match_table = panel_of_match,
	},
};

module_platform_driver(panel_driver);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("OpenKE best-effort panel driver for the Ender 3 V3 KE Nebula Pad's 480x272 panel");
