import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'admin_models.dart';
import 'admin_providers.dart';

class AdminControlScreen extends ConsumerStatefulWidget {
  const AdminControlScreen({super.key});
  @override
  ConsumerState<AdminControlScreen> createState() => _AdminControlScreenState();
}

class _AdminControlScreenState extends ConsumerState<AdminControlScreen> {
  int _tab = 0;
  final _search = TextEditingController();
  String _query = '';
  @override void dispose() { _search.dispose(); super.dispose(); }
  void _refresh() {
    ref.invalidate(adminDashboardProvider); ref.invalidate(adminUsersProvider(_query));
    ref.invalidate(adminWorkspacesProvider(_query)); ref.invalidate(adminAuditProvider);
  }
  @override
  Widget build(BuildContext context) {
    final access = ref.watch(isPlatformAdminProvider);
    return access.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => _StateScaffold(icon: Icons.cloud_off_outlined, title: 'Admin Control is unavailable', detail: _safe(e)),
      data: (allowed) => !allowed
          ? const _StateScaffold(icon: Icons.admin_panel_settings_outlined, title: 'Platform access required', detail: 'This account does not have platform-admin access.')
          : Scaffold(
              appBar: AppBar(title: Text(['Control Center','Workspaces','Users','Security','Settings'][_tab]), actions: [IconButton(tooltip:'Refresh',onPressed:_refresh,icon:const Icon(Icons.refresh))]),
              body: IndexedStack(index:_tab, children:[_Dashboard(onNavigate:(i)=>setState(()=>_tab=i)), _Workspaces(query:_query,onQuery:_setQuery), _Users(query:_query,onQuery:_setQuery), const _Security(), const _Settings()]),
              bottomNavigationBar: NavigationBar(selectedIndex:_tab,onDestinationSelected:(i)=>setState(()=>_tab=i),destinations:const [NavigationDestination(icon:Icon(Icons.dashboard_outlined),selectedIcon:Icon(Icons.dashboard),label:'Dashboard'),NavigationDestination(icon:Icon(Icons.domain_outlined),selectedIcon:Icon(Icons.domain),label:'Workspaces'),NavigationDestination(icon:Icon(Icons.people_outline),selectedIcon:Icon(Icons.people),label:'Users'),NavigationDestination(icon:Icon(Icons.shield_outlined),selectedIcon:Icon(Icons.shield),label:'Security'),NavigationDestination(icon:Icon(Icons.tune_outlined),selectedIcon:Icon(Icons.tune),label:'Settings')]),
            ),
    );
  }
  void _setQuery(String value) { setState(() => _query = value.trim()); }
}

class _Dashboard extends ConsumerWidget { const _Dashboard({required this.onNavigate}); final ValueChanged<int> onNavigate;
 @override Widget build(BuildContext context,WidgetRef ref) { final data=ref.watch(adminDashboardProvider); return RefreshIndicator(onRefresh:() async=>ref.invalidate(adminDashboardProvider),child:data.when(loading:()=>const Center(child:CircularProgressIndicator()),error:(e,_)=>_ErrorRetry(error:e,onRetry:()=>ref.invalidate(adminDashboardProvider)),data:(d)=>ListView(padding:const EdgeInsets.fromLTRB(16,12,16,24),children:[if(d.maintenance['enabled']==true) _Banner(title:'Maintenance is active',detail:d.maintenance['message'] as String? ?? 'Normal access is restricted.',icon:Icons.construction_rounded,color:Theme.of(context).colorScheme.error), _Grid(items:[_Metric('Workspaces',d.workspaces,Icons.domain_outlined,()=>onNavigate(1)),_Metric('Active users',d.activeUsers,Icons.people_outline,()=>onNavigate(2)),_Metric('Blocked users',d.blockedUsers,Icons.person_off_outlined,()=>onNavigate(2)),_Metric('Pending invites',d.pendingInvites,Icons.mail_outline,()=>onNavigate(3))]),const SizedBox(height:18),Text('Recent security events',style:Theme.of(context).textTheme.titleMedium),const SizedBox(height:8),if(d.events.isEmpty) const _Empty(icon:Icons.verified_user_outlined,title:'No recent privileged activity',detail:'Sensitive admin actions will appear here.'),...d.events.map((e)=>Card(child:ListTile(leading:Icon(e['result']=='success'?Icons.check_circle_outline:Icons.error_outline),title:Text(_label(e['action'])),subtitle:Text(e['occurred_at']?.toString() ?? ''),trailing:Text(e['result']?.toString() ?? ''))))])));}}
class _Workspaces extends ConsumerWidget { const _Workspaces({required this.query,required this.onQuery}); final String query; final ValueChanged<String> onQuery;
 @override Widget build(BuildContext c,WidgetRef r){final rows=r.watch(adminWorkspacesProvider(query));return Column(children:[_Search(onChanged:onQuery,hint:'Search workspaces'),Expanded(child:rows.when(loading:()=>const Center(child:CircularProgressIndicator()),error:(e,_)=>_ErrorRetry(error:e,onRetry:()=>r.invalidate(adminWorkspacesProvider(query))),data:(items)=>items.isEmpty?const _Empty(icon:Icons.domain_disabled_outlined,title:'No workspaces found',detail:'Try a different search term.'):RefreshIndicator(onRefresh:()async=>r.invalidate(adminWorkspacesProvider(query)),child:ListView.builder(padding:const EdgeInsets.only(bottom:20),itemCount:items.length,itemBuilder:(_,i)=>_WorkspaceTile(item:items[i])))))]);}}
class _WorkspaceTile extends ConsumerWidget { const _WorkspaceTile({required this.item}); final AdminWorkspace item;
 @override Widget build(BuildContext c,WidgetRef r)=>Card(child:ListTile(leading:CircleAvatar(child:Icon(item.status=='active'?Icons.domain:Icons.pause_circle_outline)),title:Text(item.name),subtitle:Text('${item.members} active members • ${item.status}'),trailing:PopupMenuButton<String>(onSelected:(value)=>_change(c,r,value),itemBuilder:(_)=>const [PopupMenuItem(value:'active',child:Text('Activate')),PopupMenuItem(value:'suspended',child:Text('Suspend')),PopupMenuItem(value:'archived',child:Text('Archive'))])));
 Future<void> _change(BuildContext c,WidgetRef r,String status) async {final reason=await _reason(c,'${_label(status)} workspace');if(reason==null)return;try{await r.read(adminRepositoryProvider).setWorkspaceStatus(item.id,status,reason);r.invalidate(adminWorkspacesProvider(''));r.invalidate(adminDashboardProvider);if(c.mounted)ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content:Text('Workspace status updated.')));}catch(e){if(c.mounted)ScaffoldMessenger.of(c).showSnackBar(SnackBar(content:Text(_safe(e))));}}
}
class _Users extends ConsumerWidget { const _Users({required this.query,required this.onQuery}); final String query; final ValueChanged<String> onQuery;
 @override Widget build(BuildContext c,WidgetRef r){final rows=r.watch(adminUsersProvider(query));return Column(children:[_Search(onChanged:onQuery,hint:'Name, email, or workspace'),Expanded(child:rows.when(loading:()=>const Center(child:CircularProgressIndicator()),error:(e,_)=>_ErrorRetry(error:e,onRetry:()=>r.invalidate(adminUsersProvider(query))),data:(items)=>items.isEmpty?const _Empty(icon:Icons.person_search_outlined,title:'No users found',detail:'Search by name, email, or workspace.'):ListView.builder(padding:const EdgeInsets.only(bottom:20),itemCount:items.length,itemBuilder:(_,i)=>_UserTile(item:items[i],query:query)) ))]);}}
class _UserTile extends ConsumerWidget { const _UserTile({required this.item,required this.query}); final AdminUser item; final String query;
 @override Widget build(BuildContext c,WidgetRef r)=>Card(child:ListTile(leading:CircleAvatar(child:Text(item.name.isEmpty?'?':item.name.substring(0,1).toUpperCase())),title:Text(item.name),subtitle:Text('${item.email}\n${item.workspace} • ${item.role}'),isThreeLine:true,trailing:TextButton(onPressed:()=>_block(c,r),child:Text(item.active?'Block':'Unblock'))));
 Future<void> _block(BuildContext c,WidgetRef r) async {final action=item.active?'Block':'Unblock';final reason=await _reason(c,'$action ${item.name}');if(reason==null)return;try{await r.read(adminRepositoryProvider).setUserBlocked(item.id,item.active,reason);r.invalidate(adminUsersProvider(query));r.invalidate(adminDashboardProvider);if(c.mounted)ScaffoldMessenger.of(c).showSnackBar(SnackBar(content:Text('$action action recorded.')));}catch(e){if(c.mounted)ScaffoldMessenger.of(c).showSnackBar(SnackBar(content:Text(_safe(e))));}}
}
class _Security extends ConsumerWidget { const _Security(); @override Widget build(BuildContext c,WidgetRef r){final data=r.watch(adminAuditProvider);return data.when(loading:()=>const Center(child:CircularProgressIndicator()),error:(e,_)=>_ErrorRetry(error:e,onRetry:()=>r.invalidate(adminAuditProvider)),data:(items)=>items.isEmpty?const _Empty(icon:Icons.policy_outlined,title:'No audited admin actions',detail:'Changes to blocks, workspaces, and maintenance will be logged here.'):RefreshIndicator(onRefresh:()async=>r.invalidate(adminAuditProvider),child:ListView.builder(itemCount:items.length,itemBuilder:(_,i){final a=items[i];return Card(child:ListTile(leading:Icon(a.result=='success'?Icons.verified_outlined:Icons.warning_amber_rounded),title:Text(_label(a.action)),subtitle:Text(a.occurredAt),trailing:Text(a.result)));})));}}
class _Settings extends ConsumerStatefulWidget { const _Settings(); @override ConsumerState<_Settings> createState()=>_SettingsState(); }
class _SettingsState extends ConsumerState<_Settings> { final _title=TextEditingController(text:'FactoryFlow maintenance');final _message=TextEditingController(text:'FactoryFlow is temporarily unavailable while we apply maintenance.');bool _enabled=false,_saving=false;@override void dispose(){_title.dispose();_message.dispose();super.dispose();}@override Widget build(BuildContext c)=>ListView(padding:const EdgeInsets.all(16),children:[Text('Maintenance mode',style:Theme.of(c).textTheme.titleMedium),const SizedBox(height:4),const Text('Platform administrators retain access. Changes are server-authorized and audited.'),SwitchListTile(value:_enabled,onChanged:(v)=>setState(()=>_enabled=v),title:const Text('Enable maintenance mode')),TextField(controller:_title,decoration:const InputDecoration(labelText:'Title')),const SizedBox(height:12),TextField(controller:_message,minLines:3,maxLines:5,decoration:const InputDecoration(labelText:'Message')),const SizedBox(height:16),FilledButton.icon(onPressed:_saving?null:_save,icon:const Icon(Icons.save_outlined),label:Text(_saving?'Saving…':'Save maintenance settings')),const SizedBox(height:24),Text('Permission model',style:Theme.of(c).textTheme.titleMedium),const Card(child:ListTile(leading:Icon(Icons.admin_panel_settings_outlined),title:Text('Platform admin'),subtitle:Text('Can manage platform users, workspaces, maintenance, audit, and health. This is separate from workspace owner/admin roles.')))]);
 Future<void> _save() async{setState(()=>_saving=true);try{await ref.read(adminRepositoryProvider).setMaintenance(enabled:_enabled,title:_title.text,message:_message.text);ref.invalidate(adminDashboardProvider);if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Maintenance settings saved and audited.')));}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(_safe(e))));}finally{if(mounted)setState(()=>_saving=false);}}
}
class _Search extends StatelessWidget{const _Search({required this.onChanged,required this.hint});final ValueChanged<String> onChanged;final String hint;@override Widget build(BuildContext c)=>Padding(padding:const EdgeInsets.fromLTRB(16,10,16,6),child:TextField(onChanged:onChanged,decoration:InputDecoration(prefixIcon:const Icon(Icons.search),hintText:hint,contentPadding:const EdgeInsets.symmetric(horizontal:16,vertical:12))));}
class _Grid extends StatelessWidget {
  const _Grid({required this.items});

  final List<_Metric> items;

  @override
  Widget build(BuildContext context) => GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 1.55,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        children: items
            .map(
              (metric) => Card(
                margin: EdgeInsets.zero,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: metric.tap,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(metric.icon, size: 20),
                        const Spacer(),
                        Text(
                          '${metric.value}',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        Text(
                          metric.label,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      );
}
class _Metric{const _Metric(this.label,this.value,this.icon,this.tap);final String label;final int value;final IconData icon;final VoidCallback tap;}
class _Banner extends StatelessWidget{const _Banner({required this.title,required this.detail,required this.icon,required this.color});final String title,detail;final IconData icon;final Color color;@override Widget build(BuildContext c)=>Card(color:color.withValues(alpha:.1),child:ListTile(leading:Icon(icon,color:color),title:Text(title),subtitle:Text(detail)));}
class _Empty extends StatelessWidget{const _Empty({required this.icon,required this.title,required this.detail});final IconData icon;final String title,detail;@override Widget build(BuildContext c)=>Center(child:Padding(padding:const EdgeInsets.all(36),child:Column(mainAxisSize:MainAxisSize.min,children:[Icon(icon,size:48,color:Theme.of(c).colorScheme.outline),const SizedBox(height:12),Text(title,style:Theme.of(c).textTheme.titleMedium,textAlign:TextAlign.center),const SizedBox(height:6),Text(detail,textAlign:TextAlign.center)])));}
class _StateScaffold extends StatelessWidget{const _StateScaffold({required this.icon,required this.title,required this.detail});final IconData icon;final String title,detail;@override Widget build(BuildContext c)=>Scaffold(body:_Empty(icon:icon,title:title,detail:detail));}
class _ErrorRetry extends StatelessWidget{const _ErrorRetry({required this.error,required this.onRetry});final Object error;final VoidCallback onRetry;@override Widget build(BuildContext c)=>Center(child:Column(mainAxisSize:MainAxisSize.min,children:[Text(_safe(error)),TextButton(onPressed:onRetry,child:const Text('Try again'))]));}
Future<String?> _reason(BuildContext c,String action){final controller=TextEditingController();return showDialog<String>(context:c,builder:(d)=>AlertDialog(title:Text(action),content:TextField(controller:controller,autofocus:true,maxLines:3,decoration:const InputDecoration(labelText:'Required reason')),actions:[TextButton(onPressed:()=>Navigator.pop(d),child:const Text('Cancel')),FilledButton(onPressed:()=>controller.text.trim().isEmpty?null:Navigator.pop(d,controller.text.trim()),child:const Text('Confirm'))]));}
String _label(Object? value)=>(value?.toString() ?? '').replaceAll('_',' ');
String _safe(Object error){final raw=error.toString();return raw.length>160?'Action failed. Check your connection and permissions.':raw.replaceFirst('Exception: ','');}
