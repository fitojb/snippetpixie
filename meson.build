project('com.github.bytepixie.snippetpixie', 'vala', 'c')

gnome = import('gnome')
i18n = import('i18n')

add_global_arguments('-DGETTEXT_PACKAGE="@0@"'.format (meson.project_name()), language:'c')
add_global_arguments('-DWNCK_I_KNOW_THIS_IS_UNSTABLE', language:'c')

asresources = gnome.compile_resources(
    'as-resources', 'data/' + meson.project_name() + '.gresource.xml',
    source_dir: 'data',
    c_name: 'as'
)

executable(
    meson.project_name(),
    'src/Application.vala',
    'src/FramedTextView.vala',
    'src/MainWindow.vala',
    'src/MainWindowHeader.vala',
    'src/Snippet.vala',
    'src/SnippetsList.vala',
    'src/SnippetsListItem.vala',
    'src/SnippetsManager.vala',
    'src/Utils.vala',
    'src/ViewStack.vala',
    'src/WelcomeView.vala',
    asresources,
    dependencies: [
        dependency('atspi-2', version: '>=2.0'),
        dependency('gdk-x11-3.0'),
        dependency('gee-0.8'),
        dependency('glib-2.0'),
        dependency('gobject-2.0'),
        dependency('granite', version: '>=0.5'),
        dependency('gtk+-3.0'),
        dependency('ibus-1.0'),
        dependency('json-glib-1.0'),
        dependency('sqlite3'),
        dependency('libwnck-3.0'),
        dependency('xtst'),
        dependency('x11', version: '>=1.0'),
        meson.get_compiler('c').find_library('m', required : false)
    ],
    install: true
)
subdir('data')
subdir('po')

meson.add_install_script('meson/post_install.py')

install_man('man/snippetpixie.1')
install_man('man/snippetpixie-placeholders.5')
