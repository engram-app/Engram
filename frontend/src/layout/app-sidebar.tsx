import FilesPanel from './files-panel'
import Rail from './rail'
import SearchPanel from './search-panel'
import { useRailView } from './rail-view-context'

export default function AppSidebar() {
  const { view } = useRailView()
  return (
    <>
      <Rail />
      {view === 'files' ? <FilesPanel /> : <SearchPanel />}
    </>
  )
}
