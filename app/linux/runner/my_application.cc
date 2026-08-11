#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#include <unistd.h>

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <glib/gstdio.h>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWidget* stack;   // GtkStack：splash / flutter 两层
  GtkWidget* splash;  // 原生启动画面（Flutter 首帧后销毁）
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Resolve the directory of the running executable (the bundle root), used to
// locate the application icon bundled at data/app_icon.png.
static gchar* resolve_exe_dir() {
  gchar buf[4096];
  const ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
  if (n <= 0) return nullptr;
  buf[n] = '\0';
  return g_path_get_dirname(buf);
}

// Resolve the absolute path of the running executable (bundle binary).
static gchar* resolve_exe_path() {
  gchar buf[4096];
  const ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
  if (n <= 0) return nullptr;
  buf[n] = '\0';
  return g_strdup(buf);
}

// 用户级 .desktop 条目路径（~/.local/share/applications/<APPLICATION_ID>.desktop）。
// 失败（无用户数据目录）返回 nullptr。
static gchar* desktop_entry_path() {
  const gchar* data_dir = g_get_user_data_dir();  // $XDG_DATA_HOME | ~/.local/share
  if (data_dir == nullptr) return nullptr;
  g_autofree gchar* apps_dir =
      g_build_filename(data_dir, "applications", nullptr);
  if (g_mkdir_with_parents(apps_dir, 0755) != 0) return nullptr;
  return g_build_filename(apps_dir, APPLICATION_ID ".desktop", nullptr);
}

// 安装用户级 .desktop 条目。
// 桌面环境（GNOME/KDE，尤其 Wayland 合成器）按窗口 app_id 查找对应 .desktop
// 来决定任务栏/面板图标，窗口级 gtk_window_set_icon 在 Wayland 下会被忽略，
// 因此 bundle 直跑（无系统安装）的应用需自建该条目，才能把 Logo 映射到任务栏。
//
// 清理策略（暂简化为「启动时写入 + 启动自愈」）：不做退出时的删除管理；
// 若已有条目 Exec 指向的可执行文件已不存在（bundle 被移动/删除），下次启动时
// 先移除再重建，避免桌面启动器残留一个打不开的入口。
static void install_desktop_entry(const gchar* exe_path,
                                  const gchar* icon_path) {
  g_autofree gchar* desktop_path = desktop_entry_path();
  if (desktop_path == nullptr) return;

  // 自愈：清理 Exec 已失效的旧条目（内容有效性优先于内容相等判断）。
  g_autofree gchar* old = nullptr;
  GError* read_err = nullptr;
  g_file_get_contents(desktop_path, &old, nullptr, &read_err);
  g_clear_error(&read_err);
  if (old != nullptr) {
    g_autoptr(GKeyFile) kf = g_key_file_new();
    if (g_key_file_load_from_data(kf, old, -1, G_KEY_FILE_NONE, nullptr)) {
      g_autofree gchar* exec =
          g_key_file_get_string(kf, "Desktop Entry", "Exec", nullptr);
      if (exec != nullptr) {
        g_autofree gchar* exec_path = g_shell_unquote(exec, nullptr);
        if (exec_path != nullptr && !g_file_test(exec_path, G_FILE_TEST_EXISTS)) {
          g_unlink(desktop_path);
        }
      }
    }
  }

  // 重新写入（路径可能因 bundle 移动而更新）。
  g_autofree gchar* content = g_strdup_printf(
      "[Desktop Entry]\n"
      "Type=Application\n"
      "Name=ArchoeraMusic\n"
      "Comment=Archoera Music Player\n"
      "Exec=\"%s\"\n"
      "Icon=%s\n"
      "Terminal=false\n"
      "Categories=Audio;Music;Player;\n"
      "StartupWMClass=%s\n",
      exe_path, icon_path, APPLICATION_ID);
  GError* error = nullptr;
  if (!g_file_set_contents(desktop_path, content, -1, &error)) {
    g_warning("Failed to write desktop entry %s: %s", desktop_path,
              error ? error->message : "unknown");
    g_clear_error(&error);
  }
}

// ---- 原生启动画面（静态）------------------------------------------------
// 按 Flutter 桌面加载逻辑：桌面端没有统一的 Splash API（flutter_native_splash
// 官方不支持），首帧前 C 层只能显示静态画面。因此 C 层仅做**静态**覆盖——
// 深色背景 + 居中品牌 Logo（不绘制任何动画），动画一律由 Flutter 侧
// SplashScreen（首帧后的 SplashPage）承担。窗口立即显示（覆盖引擎加载期），
// Flutter 首帧后 crossfade 切换到视图。

static GtkWidget* create_splash(GdkPixbuf* logo) {
  GtkWidget* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  gtk_widget_set_size_request(box, 480, 320);
  // 背景对齐 Flutter AppPalette.dark.surface（#0E1117），避免切换跳变。
  GtkCssProvider* provider = gtk_css_provider_new();
  gtk_css_provider_load_from_data(
      provider, "* { background-color: #0E1117; }", -1, nullptr);
  gtk_style_context_add_provider(
      gtk_widget_get_style_context(box), GTK_STYLE_PROVIDER(provider),
      GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  g_object_unref(provider);

  if (logo != nullptr) {
    // 缩放到 54px 居中显示（图标本身为 512px 品牌 Logo）。
    GdkPixbuf* scaled =
        gdk_pixbuf_scale_simple(logo, 54, 54, GDK_INTERP_BILINEAR);
    if (scaled != nullptr) {
      GtkWidget* image = gtk_image_new_from_pixbuf(scaled);
      g_object_unref(scaled);
      gtk_widget_set_halign(image, GTK_ALIGN_CENTER);
      gtk_widget_set_valign(image, GTK_ALIGN_CENTER);
      gtk_box_pack_start(GTK_BOX(box), image, TRUE, TRUE, 0);
    }
  }
  return box;
}

// 等 crossfade 过渡结束后销毁原生启动画面。
static gboolean destroy_splash_cb(gpointer user_data) {
  MyApplication* self = static_cast<MyApplication*>(user_data);
  if (self->splash != nullptr) {
    gtk_widget_destroy(self->splash);
    self->splash = nullptr;
  }
  return G_SOURCE_REMOVE;
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  // 引擎首帧就绪：切换到 Flutter 视图，原生启动画面稍后销毁（让出 crossfade）。
  // 窗口在 activate 时已显示（原生启动画面），此处不再 show。
  if (self->stack != nullptr) {
    gtk_stack_set_visible_child_name(GTK_STACK(self->stack), "flutter");
  }
  if (self->splash != nullptr) {
    g_timeout_add(260, destroy_splash_cb, self);
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "archoera_music");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "archoera_music");
  }

  gtk_window_set_default_size(window, 1280, 720);

  // 窗口/任务栏图标 + 启动画面 Logo：bundle 内 data/app_icon.png（品牌 Logo）。
  GdkPixbuf* splash_logo = nullptr;
  g_autofree gchar* exe_dir = resolve_exe_dir();
  g_autofree gchar* exe_path = resolve_exe_path();
  if (exe_dir != nullptr) {
    g_autofree gchar* icon_path =
        g_build_filename(exe_dir, "data", "app_icon.png", nullptr);
    // 自建用户级 .desktop 条目（Wayland 任务栏按 app_id 映射图标，见函数注释）。
    if (exe_path != nullptr) {
      install_desktop_entry(exe_path, icon_path);
    }
    g_autoptr(GError) icon_error = nullptr;
    g_autoptr(GdkPixbuf) icon =
        gdk_pixbuf_new_from_file(icon_path, &icon_error);
    if (icon != nullptr) {
      gtk_window_set_icon(window, icon);
      splash_logo = icon;
    }
  }

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // 背景对齐 Flutter AppPalette.dark.surface（#0E1117），避免启动画面跳变。
  gdk_rgba_parse(&background_color, "#0E1117");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));

  // 启动画面 + Flutter 视图叠放于 GtkStack：先显示原生启动画面（覆盖引擎
  // 加载期黑屏），Flutter 首帧后 crossfade 切换到视图（见 first_frame_cb）。
  GtkWidget* stack = gtk_stack_new();
  gtk_stack_set_transition_type(GTK_STACK(stack),
                                GTK_STACK_TRANSITION_TYPE_CROSSFADE);
  gtk_stack_set_transition_duration(GTK_STACK(stack), 240);
  self->stack = stack;
  self->splash = create_splash(splash_logo);
  gtk_stack_add_named(GTK_STACK(stack), self->splash, "splash");
  gtk_stack_set_visible_child_name(GTK_STACK(stack), "splash");
  gtk_stack_add_named(GTK_STACK(stack), GTK_WIDGET(view), "flutter");
  gtk_container_add(GTK_CONTAINER(window), stack);
  gtk_widget_show(stack);
  // 立即显示窗口：原生启动画面已就绪，覆盖 Flutter 引擎加载期；
  // 首帧后由 first_frame_cb 切换到 Flutter 视图。
  gtk_widget_show(GTK_WIDGET(window));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
