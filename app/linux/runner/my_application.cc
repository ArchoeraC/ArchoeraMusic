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
  // 注：不再自建用户级 .desktop 条目——Linux 分发统一走 packaging 各格式，
  // 由系统安装 .desktop（Wayland 任务栏据此映射图标）；任务栏图标依赖系统条目。
  GdkPixbuf* splash_logo = nullptr;
  g_autofree gchar* exe_dir = resolve_exe_dir();
  if (exe_dir != nullptr) {
    g_autofree gchar* icon_path =
        g_build_filename(exe_dir, "data", "app_icon.png", nullptr);
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
