import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final model = AppModel();
  await model.initialize();
  runApp(NaviaApp(model: model));
}

class NaviaApp extends StatefulWidget {
  final AppModel model;
  const NaviaApp({super.key, required this.model});
  @override
  State<NaviaApp> createState() => _NaviaAppState();
}

class _NaviaAppState extends State<NaviaApp> with WidgetsBindingObserver {
  int page = 0;
  AppModel get m => widget.model;
  String t(String cs, String en) => m.t(cs, en);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(m.pause());
    if (state == AppLifecycleState.resumed) unawaited(m.resume());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: m,
    builder: (context, _) {
      return MaterialApp(
        title: 'OpenLauf',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff006b68)),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff006b68),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: Scaffold(
          appBar: AppBar(
            title: const Text('OpenLauf'),
            actions: [
              IconButton(
                tooltip: t('Jazyk', 'Language'),
                onPressed: () => m.language(!m.english),
                icon: Text(m.english ? 'EN' : 'CS'),
              ),
              IconButton(
                tooltip: t('Obnovit stav', 'Refresh state'),
                onPressed: m.ready && !m.busy && !m.stopping
                    ? () => m.run(() => m.client!.refresh())
                    : null,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: Builder(
            builder: (context) => Column(
              children: [
                if (m.busy || m.stopping) const LinearProgressIndicator(),
                ListTile(
                  leading: Icon(
                    m.ready ? Icons.bluetooth_connected : Icons.bluetooth,
                  ),
                  title: Text(m.stage),
                  subtitle: Text(
                    m.ready
                        ? stateName(m.client?.state?.code)
                        : t(
                            'Místní Bluetooth • bez účtu',
                            'Local Bluetooth • no account',
                          ),
                  ),
                ),
                if (m.error.isNotEmpty)
                  MaterialBanner(
                    content: Text(m.error),
                    actions: [
                      TextButton(
                        onPressed: () {
                          m.error = '';
                          m.changed();
                        },
                        child: Text(t('Zavřít', 'Dismiss')),
                      ),
                    ],
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                    children: [
                      if (!m.ready) ...connection(),
                      ...switch (page) {
                        0 => controls(),
                        1 => settings(),
                        2 => maintenance(context),
                        _ => diagnostics(),
                      },
                    ],
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: page,
            onDestinationSelected: (value) => setState(() => page = value),
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.water_drop_outlined),
                label: t('Ovládání', 'Control'),
              ),
              NavigationDestination(
                icon: const Icon(Icons.tune),
                label: t('Nastavení', 'Settings'),
              ),
              NavigationDestination(
                icon: const Icon(Icons.cleaning_services_outlined),
                label: t('Údržba', 'Care'),
              ),
              NavigationDestination(
                icon: const Icon(Icons.info_outline),
                label: t('Diagnostika', 'Diagnostics'),
              ),
            ],
          ),
        ),
      );
    },
  );
  Widget section(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );
  List<Widget> connection() => [
    section(t('Tvoje Navia', 'Your Navia'), [
      Text(
        t(
          'Zapni Bluetooth a vyhledej WC v blízkosti. Během testu odpoj původní aplikaci a jiné BLE nástroje.',
          'Enable Bluetooth and find a nearby toilet. Disconnect the original app and other BLE tools during testing.',
        ),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: m.busy || m.stopping || m.scanning ? null : m.scan,
        icon: const Icon(Icons.search),
        label: Text(
          m.scanning
              ? t('Hledání…', 'Scanning…')
              : t('Vyhledat WC', 'Find toilet'),
        ),
      ),
      for (final d in m.devices.values)
        ListTile(
          title: Text(d['name'] as String),
          subtitle: Text(
            '${d['rssi']} dBm • ${d['connectable'] == true ? t("dostupné", "available") : t("nyní nepřipojitelné", "not connectable now")}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: !m.busy && !m.stopping && d['connectable'] == true
              ? () => m.connect(d['id'] as String)
              : null,
        ),
    ]),
  ];
  bool get writable =>
      m.ready && !m.busy && !m.stopping && m.client?.state?.descaling != true;
  Widget action(
    String label,
    int event,
    IconData icon, {
    bool enabled = true,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: FilledButton.tonalIcon(
      onPressed: event == 5
          ? (m.canStop && enabled ? m.stopShower : null)
          : (writable && enabled
                ? () => m.run(() => m.client!.action(event))
                : null),
      icon: Icon(icon),
      label: Padding(padding: const EdgeInsets.all(12), child: Text(label)),
    ),
  );
  List<Widget> controls() => [
    section(t('Sprchování', 'Shower'), [
      action(
        t('Zadní sprcha', 'Rear shower'),
        2,
        Icons.water_drop,
        enabled: m.client?.state?.code == 2,
      ),
      action(
        t('Dámská sprcha', 'Lady shower'),
        1,
        Icons.water_drop_outlined,
        enabled: m.client?.state?.code == 2,
      ),
      action('Stop', 5, Icons.stop_circle_outlined),
    ]),
    section(t('Zadní sprcha', 'Rear shower'), [
      parameter(t('Tlak', 'Pressure'), 0, 1, 7),
      parameter(t('Poloha trysky', 'Jet position'), 1, 1, 7),
      action(
        t('Přepnout oscilaci', 'Toggle oscillation'),
        0x22,
        Icons.swap_vert,
      ),
    ]),
    section(t('Dámská sprcha', 'Lady shower'), [
      parameter(t('Tlak', 'Pressure'), 5, 1, 7),
      parameter(t('Poloha trysky', 'Jet position'), 6, 1, 7),
      action(
        t('Přepnout oscilaci', 'Toggle oscillation'),
        0x23,
        Icons.swap_vert,
      ),
    ]),
    section(t('Teplota vody', 'Water temperature'), [
      parameter(t('Úroveň', 'Level'), 10, 1, 7),
    ]),
  ];
  Widget parameter(String title, int key, int min, int max) {
    final value = m.client?.profile[key];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$title: ${value ?? "—"}'),
        if (value != null && (value < min || value > max))
          Text(
            t(
              'Hodnota mimo ověřený rozsah; zápis je vypnutý.',
              'Value outside known range; writing disabled.',
            ),
          ),
        CommitSlider(
          key: ValueKey('parameter-$key'),
          value: (value ?? min).clamp(min, max).toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          onCommit: writable && value != null && value >= min && value <= max
              ? (v) => m.run(() => m.client!.setParameter(0, key, v.round()))
              : null,
        ),
      ],
    );
  }

  List<Widget> settings() => [
    section(t('Základní profil', 'Basic profile'), [
      Text(
        t(
          'Navia ukládá základní profil přímo do WC. Změny se ověřují zpětným načtením.',
          'Navia stores its basic profile in the toilet. Writes are checked by reading back.',
        ),
      ),
      action(
        t('Uložit nastavení do WC', 'Save settings to toilet'),
        0x50,
        Icons.save_outlined,
      ),
      Text(
        t(
          'Délku sprchování zatím ponecháváme beze změny: rozsahy v původním kódu si odporují.',
          'Shower duration is currently read-only: the original metadata has conflicting ranges.',
        ),
      ),
      Text(
        '${t("Délka – zadní / přední (raw)", "Duration – rear / front (raw)")}: ${m.client?.profile[2] ?? "—"} / ${m.client?.profile[7] ?? "—"}',
      ),
    ]),
    section(t('Voda a ohřev', 'Water and heating'), [
      setting(t('Ohřev vody', 'Heater'), 0x10, {0: 'Off', 1: 'Eco', 2: 'On'}),
      setting(t('Tvrdost vody', 'Water hardness'), 0x11, {
        1: '< 8.4 °dH',
        2: '8.4–14 °dH',
        3: '14–19.7 °dH',
        4: '> 19.7 °dH',
      }),
    ]),
  ];
  Widget setting(String title, int key, Map<int, String> choices) {
    final value = m.client?.settings[key];
    return DropdownButtonFormField<int>(
      key: ValueKey('$key-$value'),
      initialValue: choices.containsKey(value) ? value : null,
      decoration: InputDecoration(labelText: title),
      items: choices.entries
          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
          .toList(),
      onChanged: writable
          ? (v) {
              if (v != null) {
                unawaited(m.run(() => m.client!.setParameter(255, key, v)));
              }
            }
          : null,
    );
  }

  Future<bool> confirm(
    BuildContext context,
    String title,
    String message,
  ) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t('Zpět', 'Back')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t('Potvrdit', 'Confirm')),
            ),
          ],
        ),
      ) ??
      false;
  List<Widget> maintenance(BuildContext context) {
    final state = m.client?.state;
    final active = state?.code == 16;
    final preparation = state?.code == 12 || state?.code == 15;
    return [
      section(t('Odvápnění', 'Descaling'), [
        Text(stateName(state?.code)),
        Text(
          t(
            'Použij přípravek určený pro Cleanet Navia podle návodu výrobce. Po spuštění cyklus nejde přerušit.',
            'Use the descaler specified for Cleanet Navia according to its manual. An active cycle cannot be interrupted.',
          ),
        ),
        if (preparation)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              t(
                'Otevři boční krytku a vlož tři originální odvápňovací tablety. Krytku zavři. WC může přejít do cyklu samo.',
                'Open the side cover and insert three original descaling tablets. Close the cover. The toilet may start the cycle automatically.',
              ),
            ),
          ),
        if (active)
          Text(
            '${t("Zbývající čas", "Remaining time")}: ${m.client?.remainingSeconds == null ? "—" : "${(m.client!.remainingSeconds! / 60).ceil()} min"}',
          ),
        FilledButton(
          onPressed:
              m.ready &&
                  !m.busy &&
                  !m.stopping &&
                  (state?.code == 2 || preparation) &&
                  m.client?.info?.descalingSupported == true
              ? () async {
                  if (!await confirm(
                    context,
                    t('Odvápnění', 'Descaling'),
                    preparation
                        ? t(
                            'Jsou tablety vložené a krytka zavřená?',
                            'Are the tablets inserted and the cover closed?',
                          )
                        : t(
                            'Připrav odvápňovací tablety. Pokračovat do přípravy?',
                            'Prepare the descaling tablets. Enter preparation?',
                          ),
                  )) {
                    return;
                  }
                  await m.run(
                    () => preparation
                        ? m.client!.startDescaling()
                        : m.client!.prepareDescaling(),
                  );
                }
              : null,
          child: Text(
            preparation
                ? t(
                    'Příprava hotová – pokračovat',
                    'Preparation complete – continue',
                  )
                : t('Připravit odvápnění', 'Prepare descaling'),
          ),
        ),
        Text(
          t(
            'Telefon můžeš zamknout. Po návratu se načte skutečný stav WC; zavření aplikace cyklus neruší.',
            'You can lock the phone. On return, the actual toilet state is read again; closing the app does not cancel the cycle.',
          ),
        ),
      ]),
      section(t('Servis a proplach', 'Service and flushing'), [
        action(
          t('Vysunout trysku pro čištění', 'Extend nozzle for cleaning'),
          0x0b,
          Icons.build_outlined,
          enabled: state?.code == 1,
        ),
        action(
          t('Zasunout trysku', 'Retract nozzle'),
          0x0a,
          Icons.keyboard_return,
          enabled: state?.code == 13,
        ),
        action(
          t('Propláchnout zařízení', 'Flush appliance'),
          0x62,
          Icons.waves,
          enabled: state?.code == 2,
        ),
      ]),
    ];
  }

  List<Widget> diagnostics() => [
    section(t('Zařízení', 'Device'), [
      Text('Firmware: ${m.client?.info?.firmware ?? "—"}'),
      Text('${t("Model", "Article")}: ${m.client?.info?.article ?? "—"}'),
      Text('${t("Sériové číslo", "Serial")}: ${m.client?.info?.serial ?? "—"}'),
      Text(
        '${t("Poškozené rámce", "Rejected frames")}: ${m.client?.decoder.rejected ?? 0}',
      ),
      Text(
        '${t("Poslední aktualizace", "Last update")}: ${m.client?.lastUpdate ?? "—"}',
      ),
      OutlinedButton(
        onPressed: m.ready && !m.busy && !m.stopping
            ? () => m.run(() async {
                final alarms = await m.client!.readAlarms();
                m.error =
                    '${t("Alarmy (raw)", "Alarms (raw)")}: ${alarms.isEmpty ? t("žádné", "none") : alarms.join(", ")}';
              })
            : null,
        child: Text(t('Načíst alarmy', 'Read alarms')),
      ),
    ]),
    section(t('Záznam spojení', 'Connection log'), [
      Text(
        t(
          'Export obsahuje pouze čas, typ příkazu a délku odpovědi. Sériová čísla, adresy a payloady se neukládají.',
          'Export contains only timestamps, command types and response lengths. Serial numbers, addresses and payloads are not logged.',
        ),
      ),
      OutlinedButton.icon(
        onPressed: () => Clipboard.setData(
          ClipboardData(text: m.client?.diagnostics.join('\n') ?? ''),
        ),
        icon: const Icon(Icons.copy),
        label: Text(t('Kopírovat diagnostiku', 'Copy diagnostics')),
      ),
      SelectableText(
        m.client?.diagnostics.reversed.take(20).join('\n') ?? '—',
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    ]),
  ];
  String stateName(int? code) => switch (code) {
    1 => t('Pohotovost', 'Standby'),
    2 => t('Připraveno', 'Ready'),
    3 => t('Příprava zadní sprchy', 'Starting rear shower'),
    4 => t('Zadní sprcha běží', 'Rear shower running'),
    5 => t('Příprava dámské sprchy', 'Starting lady shower'),
    6 => t('Dámská sprcha běží', 'Lady shower running'),
    12 => t('Příprava odvápnění', 'Descaling preparation'),
    15 => t('Připraveno k odvápnění', 'Ready for descaling'),
    16 => t('Odvápňování běží', 'Descaling active'),
    13 => t('Servisní poloha', 'Service position'),
    17 || 18 => t('Ukončování sprchy', 'Stopping shower'),
    null => t('Stav není načtený', 'State not loaded'),
    _ => '${t("Stav", "State")} $code',
  };
}

/// Keep drag previews local and send exactly one setting when the drag ends.
class CommitSlider extends StatefulWidget {
  final double value, min, max;
  final ValueChanged<double>? onCommit;
  const CommitSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    this.onCommit,
  });
  @override
  State<CommitSlider> createState() => _CommitSliderState();
}

class _CommitSliderState extends State<CommitSlider> {
  double? draft;
  @override
  void didUpdateWidget(CommitSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value || widget.onCommit == null) {
      draft = null;
    }
  }

  @override
  Widget build(BuildContext context) => Slider(
    value: draft ?? widget.value,
    min: widget.min,
    max: widget.max,
    divisions: (widget.max - widget.min).round(),
    onChanged: widget.onCommit == null
        ? null
        : (v) => setState(() => draft = v),
    onChangeEnd: widget.onCommit == null
        ? null
        : (v) {
            setState(() => draft = null);
            widget.onCommit!(v);
          },
  );
}
