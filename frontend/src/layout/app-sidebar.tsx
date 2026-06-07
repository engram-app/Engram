import FilesPanel from './files-panel'
import Rail from './rail'
import SearchPanel from './search-panel'
import { useRailView } from './rail-view-context'

export default function AppSidebarPanel() {
  const { view } = useRailView()
  return view === 'files' ? <FilesPanel /> : <SearchPanel />
}

export { Rail }
