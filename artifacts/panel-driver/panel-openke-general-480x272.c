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
 * NOT CONFIRMED, best-effort defaults pending real-hardware verification:
 *   - Exact sync timing (porches/pulse widths/pixel clock) - no datasheet for this
 *     specific panel was found; the values below are a widely-documented standard
 *     timing seen across many vendor reference designs for this exact resolution
 *     class (480x272 4.3" RGB TFT), not a value read off this specific panel.
 *   - GPIO active-high/low polarity - hardcoded active-high here (this kernel's
 *     of_get_named_gpio() doesn't return the DT flags cell), easy to invert in
 *     this file if the panel powers up backwards.
 *   - Color depth/mode (RGB888 assumed here - could be RGB565/RGB666 on the real
 *     panel; wrong here would show as color-channel banding/miscoloring, not
 *     hardware risk).
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

/* Best-effort standard timing for a 480x272 4.3" RGB TFT panel - see the
 * module header comment. pixclock is in KHz, matching this driver's own
 * convention (confirmed against panel-st7701s-rgb666.c), not the picosecond
 * convention plain Linux fb.h normally uses. */
static struct fb_videomode panel_modes[] = {
	[0] = {
		.name           = "480x272",
		.refresh        = 60,
		.xres           = 480,
		.yres           = 272,
		.pixclock       = 9200,
		.left_margin    = 2,
		.right_margin   = 2,
		.upper_margin   = 2,
		.lower_margin   = 2,
		.hsync_len      = 41,
		.vsync_len      = 10,
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
